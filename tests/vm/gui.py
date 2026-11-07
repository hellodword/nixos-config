"""Wait for visible controls before sending keyboard input to a desktop VM."""

import os
import json
from datetime import timedelta
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time


class Desktop:
    """One owner for a guest's monitor, native input and activity worker."""

    def __init__(self, machine):
        self.machine = machine
        self.input_lock = threading.RLock()
        self.finished = threading.Event()
        self.ticker = None
        self.activity_error = None

    def __getattr__(self, name):
        return getattr(self.machine, name)

    def monitor(self, method, *args, timeout=10, **kwargs):
        with self.input_lock:
            sock = self.machine.monitor
            previous = sock.gettimeout()
            sock.settimeout(timeout)
            try:
                return getattr(self.machine, method)(*args, **kwargs)
            finally:
                sock.settimeout(previous)

    def send_monitor_command(self, command, timeout=10):
        return self.monitor("send_monitor_command", command, timeout=timeout)

    def send_key(self, *args, **kwargs):
        return self.monitor("send_key", *args, **kwargs)

    def send_chars(self, *args, **kwargs):
        return self.monitor("send_chars", *args, **kwargs)

    def click(self, x, y, width, height):
        self._pointer(x, y, width, height, click=True)

    def move_pointer(self, x, y, width, height):
        self._pointer(x, y, width, height, click=False)

    def _pointer(self, x, y, width, height, click):
        with self.input_lock:
            mice = self.send_monitor_command("info mice")
            tablet = re.search(r"Mouse #(\d+):[^\n]*\(absolute\)", mice)
            assert tablet, mice
            self.send_monitor_command("mouse_set " + tablet[1])
            # QMP distinguishes absolute tablet coordinates from relative mouse
            # motion. Reuse the driver's session and bound its response polling.
            client = self.machine.qmp_client
            assert client is not None
            def send(events):
                assert client.results.empty(), "QMP command still pending"
                client.writer.write(json.dumps({"execute": "input-send-event", "arguments": {"events": events}}) + "\n")
                client.writer.flush()
                deadline = time.monotonic() + 10
                while client.results.empty():
                    if time.monotonic() >= deadline:
                        raise TimeoutError("QMP input response deadline reached")
                    client.read_pending_messages()
                    time.sleep(0.01)
                return client.results.get_nowait()
            send([{"type": "abs", "data": {"axis": axis, "value": round(value * 32767 / (extent - 1))}}
                  for axis, value, extent in (("x", x, width), ("y", y, height))])
            if click:
                send([{"type": "btn", "data": {"button": "left", "down": True}}])
                time.sleep(0.15)
                send([{"type": "btn", "data": {"button": "left", "down": False}}])

    def screenshot(self, filename, timeout=15):
        deadline = time.monotonic() + timeout
        destination = Path(filename if "." in filename else filename + ".png")
        if not destination.is_absolute():
            destination = Path(self.machine.out_dir) / destination
        with self.input_lock, tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "screen.ppm"
            self.send_monitor_command(f"screendump {raw}", timeout=remaining(deadline))
            with destination.open("wb") as stream:
                subprocess.run(["pnmtopng", str(raw)], stdout=stream, stderr=subprocess.PIPE,
                               check=True, timeout=remaining(deadline))

    def keep_awake(self):
        def activity():
            try:
                while not self.finished.wait(15):
                    if self.input_lock.acquire(blocking=False):
                        try:
                            if not self.finished.is_set():
                                self.send_key("ctrl", delay=timedelta(milliseconds=150))
                        finally:
                            self.input_lock.release()
            except Exception as error:
                self.activity_error = error
        self.ticker = threading.Thread(target=activity, name=f"activity-{self.name}", daemon=True)
        self.ticker.start()

    def stop_activity(self):
        self.finished.set()
        if self.ticker is not None:
            self.ticker.join(timeout=15)
            assert not self.ticker.is_alive(), "desktop activity worker did not exit"
            self.ticker = None
        if self.activity_error:
            raise RuntimeError("desktop activity input failed") from self.activity_error

    def shutdown(self):
        if not self.machine.booted:
            return
        try:
            shell = self.machine.shell
            previous = shell.gettimeout()
            shell.settimeout(10)
            try:
                shell.sendall(b"poweroff\n")
            finally:
                shell.settimeout(previous)
            self.machine.wait_for_shutdown(timeout=timedelta(seconds=120))
        except Exception as error:
            # Release this guest even when orderly shutdown fails. The original
            # error still fails the test and its evidence remains available.
            try:
                self.machine.process.terminate()
                try:
                    self.machine.wait_for_shutdown(timeout=timedelta(seconds=10))
                except subprocess.TimeoutExpired:
                    self.machine.process.kill()
                    self.machine.wait_for_shutdown(timeout=timedelta(seconds=10))
            except Exception as cleanup:
                error.add_note("Releasing desktop VM: " + str(cleanup))
            raise

    def reboot(self):
        # Request a real reboot from the guest; a graphical greeter may handle
        # Ctrl+Alt+Delete as an interface shortcut rather than rebooting.
        self.machine.succeed("systemctl reboot --no-block", timeout=timedelta(seconds=10))
        self.machine.connected = False


def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("desktop operation deadline reached")
    return min(15, value)


def visible(machine, pattern, timeout=60, keep_active=True):
    # Bound image processing so a visibility check cannot consume the
    # desktop's entire idle interval. Idle locking is exercised separately.
    with machine.nested("waiting for visible text: " + pattern), tempfile.TemporaryDirectory() as directory:
        deadline = time.monotonic() + timeout
        frame = Path(directory) / "frame.png"
        raw = Path(directory) / "frame.ppm"
        prepared = Path(directory) / "text.ppm"
        try:
            while True:
                if keep_active:
                    machine.send_key("ctrl")
                machine.screenshot(str(frame), timeout=remaining(deadline))
                # The driver's ImageMagick build handles PNM; netpbm
                # provides the PNG decoder used for retained screenshots.
                with raw.open("wb") as stream:
                    subprocess.run(["pngtopnm", str(frame)], stdout=stream, stderr=subprocess.PIPE, check=True, timeout=remaining(deadline))
                observed = []
                for contrast in ([], ["-threshold", "50%"]):
                    if time.monotonic() >= deadline:
                        break
                    if keep_active:
                        machine.send_key("ctrl")
                    subprocess.run(
                        ["magick", str(raw), "-resize", "300%", "-colorspace", "Gray", *contrast, str(prepared)],
                        check=True, capture_output=True, timeout=remaining(deadline),
                    )
                    try:
                        result = subprocess.run(
                            ["tesseract", str(prepared), "stdout", "--oem", "1", "--psm", "11"],
                            check=True, capture_output=True, text=True,
                            timeout=remaining(deadline),
                            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
                        ).stdout
                    except subprocess.TimeoutExpired:
                        observed.append("OCR timed out for " + ("threshold" if contrast else "grayscale"))
                        continue
                    observed.append(result)
                    if re.search(pattern, result):
                        return
                assert time.monotonic() < deadline, (pattern, observed)
                time.sleep(min(1, max(0, deadline - time.monotonic())))
        except Exception as error:
            if isinstance(error, subprocess.SubprocessError):
                print("Image processing failed:", getattr(error, "stderr", None))
            raise


def login(machine):
    """Authenticate through SDDM so the real PAM wallet lifecycle runs."""
    from datetime import timedelta
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_unit("home-manager-desktop.service")
    # SDDM can render its first frame before registering the view and giving
    # the password field keyboard focus. Observe the current greeter instance
    # so this also applies to a fresh login after logout.
    machine.wait_until_succeeds(
        "pid=$(pgrep -u sddm -n -f sddm-greeter); "
        "test -n \"$pid\" && journalctl -b _PID=\"$pid\" --no-pager -o cat | grep -F 'Adding view for'",
        timeout=60,
    )
    # The selected account stays legible across greeter sizes; the password
    # placeholder is small and low contrast in Breeze.
    visible(machine, r"(?i)\bdesktop\b", timeout=90)
    delay = timedelta(milliseconds=150)
    machine.send_key("ctrl-u", delay=delay)
    machine.send_chars("synthetic-fixture-only", delay=delay)
    machine.send_key("ret", delay=delay)
