"""Wait for visible controls before sending keyboard input to a desktop VM."""

import os
import json
import csv
import io
from contextlib import contextmanager
from datetime import timedelta
from pathlib import Path
import re
import shutil
import shlex
import struct
import subprocess
import tempfile
import threading
import time


class Desktop:
    """One owner for a guest's monitor, native input and idle inhibition."""

    def __init__(self, machine):
        self.machine = machine
        self.input_lock = threading.RLock()
        self.idle_inhibited = False
        self.deadline = None
        self.input_error = None

    def __getattr__(self, name):
        return getattr(self.machine, name)

    @contextmanager
    def action(self, deadline):
        previous = self.deadline
        self.deadline = min(deadline, previous) if previous is not None else deadline
        try:
            yield
        finally:
            self.deadline = previous

    def monitor(self, method, *args, timeout=None, **kwargs):
        with self.input_lock:
            if self.input_error is not None:
                raise RuntimeError("monitor delivery is unconfirmed") from self.input_error
            budget = remaining(self.deadline) if self.deadline is not None else 30
            timeout = min(timeout, budget) if timeout is not None else budget
            sock = self.machine.monitor
            previous = sock.gettimeout()
            sock.settimeout(timeout)
            try:
                return getattr(self.machine, method)(*args, **kwargs)
            except (TimeoutError, OSError) as error:
                self.input_error = error
                raise
            finally:
                sock.settimeout(previous)

    def send_monitor_command(self, command, timeout=None):
        return self.monitor("send_monitor_command", command, timeout=timeout)

    def send_key(self, *args, **kwargs):
        kwargs.setdefault("delay", timedelta(milliseconds=150))
        return self.monitor("send_key", *args, **kwargs)

    def send_chars(self, *args, **kwargs):
        kwargs.setdefault("delay", timedelta(milliseconds=150))
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
                deadline = self.deadline or time.monotonic() + 30
                while client.results.empty():
                    if time.monotonic() >= deadline:
                        self.input_error = TimeoutError("QMP input response deadline reached")
                        raise self.input_error
                    client.read_pending_messages()
                    time.sleep(0.01)
                return client.results.get_nowait()
            send([{"type": "abs", "data": {"axis": axis, "value": round(value * 32767 / (extent - 1))}}
                  for axis, value, extent in (("x", x, width), ("y", y, height))])
            if click:
                send([{"type": "btn", "data": {"button": "left", "down": True}}])
                time.sleep(0.15)
                send([{"type": "btn", "data": {"button": "left", "down": False}}])

    def screenshot(self, filename, timeout=None):
        deadline = self.deadline or time.monotonic() + 30
        if timeout is not None:
            deadline = min(deadline, time.monotonic() + timeout)
        destination = Path(filename if "." in filename else filename + ".png")
        if not destination.is_absolute():
            destination = Path(self.machine.out_dir) / destination
        with self.input_lock, tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "screen.ppm"
            self.send_monitor_command(f"screendump {raw}", timeout=remaining(deadline))
            with destination.open("wb") as stream:
                subprocess.run(["pnmtopng", str(raw)], stdout=stream, stderr=subprocess.PIPE,
                               check=True, timeout=remaining(deadline))

    def session_command(self, command):
        return ("runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
                "systemd-run --user --quiet --wait --pipe --collect --property=RuntimeMaxSec=30s sh -c " + shlex.quote(command))

    def inhibit_idle(self):
        if self.idle_inhibited:
            return
        self.session = self.machine.succeed(self.session_command('printf %s "$XDG_CURRENT_DESKTOP"'), timeout=30)
        if "sway" in self.session:
            command = "systemctl --user stop swayidle.service"
        elif "i3" in self.session:
            settings = self.machine.succeed(self.session_command("xset q"), timeout=30)
            self.screensaver = re.search(r"timeout:\s+(\d+)\s+cycle:\s+(\d+)", settings).groups()
            command = "xset s off"
        else:
            command = "systemd-run --user --collect --unit=vm-idle-inhibit vm-idle-inhibit"
        self.machine.succeed(self.session_command(command), timeout=30)
        if "KDE" in self.session:
            self.machine.wait_until_succeeds("test -f /run/user/1000/vm-idle-inhibited", timeout=30)
        self.idle_inhibited = True

    def resume_idle(self):
        if not self.idle_inhibited:
            return
        if "sway" in self.session:
            command = "systemctl --user start swayidle.service"
        elif "i3" in self.session:
            command = "xset s " + " ".join(self.screensaver) + "; xset s reset"
        else:
            command = "systemctl --user stop vm-idle-inhibit.service"
        self.machine.succeed(self.session_command(command), timeout=30)
        self.idle_inhibited = False

    @contextmanager
    def allow_idle(self):
        running = self.idle_inhibited
        self.resume_idle()
        try:
            yield
        finally:
            if running:
                self.inhibit_idle()

    def shutdown(self):
        if not self.machine.booted:
            return
        try:
            if not self.machine.connected:
                # An initrd failure has no running shell to receive poweroff.
                self.send_monitor_command("quit")
                self.machine.wait_for_shutdown(timeout=timedelta(seconds=10))
                return
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

    def crash(self):
        if self.machine.booted:
            self.send_monitor_command("quit")
            self.machine.wait_for_shutdown(timeout=timedelta(seconds=10))
            self.idle_inhibited = False

    def reboot(self):
        self.resume_idle()
        # Request a real reboot from the guest; a graphical greeter may handle
        # Ctrl+Alt+Delete as an interface shortcut rather than rebooting.
        self.machine.succeed("systemctl reboot --no-block", timeout=timedelta(seconds=10))
        self.machine.connected = False


def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("desktop operation deadline reached")
    return value


def input_method(machine, user_command, active, deadline):
    """Confirm the focused Fcitx context before the next keyboard action."""
    command = "fcitx5-remote -s pinyin && fcitx5-remote -o" if active else "fcitx5-remote -c"
    machine.succeed(user_command(command), timeout=timedelta(seconds=remaining(deadline)))
    last = ""
    while time.monotonic() < deadline:
        status, last = machine.execute(user_command(
            "fcitx5-remote; fcitx5-remote -n"
        ), timeout=remaining(deadline))
        lines = last.strip().splitlines()
        if status == 0 and lines and lines[0] == ("2" if active else "1"):
            if not active or lines[1:] == ["pinyin"]:
                return {"state": int(lines[0]), "method": lines[-1]}
        time.sleep(0.1)
    raise AssertionError(f"Fcitx {'activation' if active else 'deactivation'} timed out: {last!r}")


def focused_window(machine, user_command, deadline=None):
    query = '''case "$XDG_CURRENT_DESKTOP" in
      *sway*) wm=swaymsg ;;
      *i3*) wm=i3-msg ;;
      *KDE*) kdotool getwindowclassname "$(kdotool getactivewindow)"; exit ;;
    esac
    "$wm" -t get_tree | jq -c 'first(.. | objects | select(.focused? == true) | {app_id, window_properties, name, pid})'
    '''
    return machine.succeed(user_command(query), timeout=timedelta(seconds=remaining(deadline) if deadline else 30)).strip()


def wait_for_session(machine, session, user_command):
    # The WM target is started after environment import and PAM wallet setup.
    # graphical-session.target alone can become active before those finish.
    target = {"sway": "site-sway.target", "i3": "site-i3.target", "KDE": "plasma-workspace.target"}[session]
    machine.wait_until_succeeds(user_command("systemctl --user is-active " + target), timeout=180)
    machine.wait_until_succeeds(user_command(
        "systemctl --user show-environment | grep '^XDG_CURRENT_DESKTOP=.*" + session + "'"
    ), timeout=60)
    machine.wait_until_succeeds(user_command("busctl --user status org.fcitx.Fcitx5"), timeout=60)


def ocr_lines(tsv, scale=2):
    """Preserve recognized text lines and join aligned fragments across a row."""
    fragments = {}
    for row in csv.DictReader(io.StringIO(tsv), delimiter="\t", quoting=csv.QUOTE_NONE):
        if row["level"] != "5" or not row["text"].strip():
            continue
        key = tuple(row[field] for field in ("page_num", "block_num", "par_num", "line_num"))
        fragments.setdefault(key, []).append({
            "text": row["text"].strip(), "confidence": float(row["conf"]),
            **{field: int(row[field]) / scale for field in ("left", "top", "width", "height")},
        })
    rows = []
    for words in fragments.values():
        top = min(word["top"] for word in words)
        bottom = max(word["top"] + word["height"] for word in words)
        rows.append({"center": (top + bottom) / 2, "height": bottom - top, "words": words})
    lines = []
    for row in sorted(rows, key=lambda item: item["center"]):
        line = min((line for line in lines
                    if abs(row["center"] - line["center"]) < min(row["height"], line["height"]) / 2),
                   key=lambda line: abs(row["center"] - line["center"]), default=None)
        if line is None:
            lines.append(row)
        else:
            line["words"].extend(row["words"])
    for line in lines:
        line["words"].sort(key=lambda item: item["left"])
        line["text"] = " ".join(word["text"] for word in line["words"])
    return lines


def visible(machine, pattern, timeout=60, rotation=0, region=None, *, layout="sparse", fallback_layout=None, consecutive=1, check=None):
    """Observe fresh frames without sending input. Retain the decisive frame."""
    page_modes = {"line": "7", "block": "6", "sparse": "11"}
    with machine.nested("waiting for visible text: " + pattern), tempfile.TemporaryDirectory() as directory:
        started = time.monotonic()
        deadline = started + timeout
        if machine.deadline is not None:
            deadline = min(deadline, machine.deadline)
        frame = Path(directory) / "frame.png"
        raw = Path(directory) / "frame.ppm"
        cropped = Path(directory) / "region.ppm"
        prepared = Path(directory) / "text.ppm"
        details = {"pattern": pattern, "region": region, "rotation": rotation,
                   "layout": layout, "fallbackLayout": fallback_layout,
                   "consecutive": consecutive, "passes": []}
        evidence = Path(machine.out_dir) / ("ocr-" + machine.name + "-" + str(time.monotonic_ns()))

        def retain(status):
            details.update(status=status, seconds=time.monotonic() - started)
            evidence.mkdir(parents=True, exist_ok=True)
            (evidence / "ocr.json").write_text(json.dumps(details, indent=2))
            if frame.exists():
                shutil.copyfile(frame, evidence / "frame.png")
            if cropped.exists():
                with (evidence / "region.png").open("wb") as stream:
                    subprocess.run(["pnmtopng", str(cropped)], stdout=stream,
                                   stderr=subprocess.PIPE, timeout=10, check=True)
            print("OCR evidence:", evidence)

        streak = 0
        try:
            while time.monotonic() < deadline:
                machine.screenshot(str(frame), timeout=remaining(deadline))
                with raw.open("wb") as stream:
                    subprocess.run(["pngtopnm", str(frame)], stdout=stream, stderr=subprocess.PIPE,
                                   check=True, timeout=remaining(deadline))
                transform = ["-rotate", str(rotation)] if rotation else []
                if region is not None:
                    width, height = struct.unpack(">II", frame.read_bytes()[16:24])
                    if rotation % 180:
                        width, height = height, width
                    x, y, w, h = (round(value * extent) for value, extent in
                                  zip(region, (width, height, width, height)))
                    transform += ["-crop", f"{w}x{h}+{x}+{y}", "+repage"]
                subprocess.run(["magick", str(raw), *transform, str(cropped)],
                               check=True, capture_output=True, timeout=remaining(deadline))
                matched = False
                # Two passes at most, then capture a fresh frame. Enlarging the
                # crop helps small labels while preserving the native desktop.
                for contrast, options, mode in (("grayscale", [], layout),
                                                ("threshold", ["-threshold", "60%"], fallback_layout or layout)):
                    if time.monotonic() >= deadline:
                        break
                    subprocess.run(["magick", str(cropped), "-resize", "200%", "-colorspace", "Gray",
                                    *options, str(prepared)],
                                   check=True, capture_output=True, timeout=remaining(deadline))
                    ocr_start = time.monotonic()
                    budget = min(8, remaining(deadline))
                    page_mode = page_modes[mode]
                    observation = {"frameSeconds": ocr_start - started, "contrast": contrast, "psm": page_mode}
                    details["passes"].append(observation)
                    try:
                        result = subprocess.run(
                            ["tesseract", str(prepared), "stdout", "--oem", "1", "--psm", page_mode, "tsv"],
                            check=True, capture_output=True, text=True, timeout=budget,
                            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
                        )
                    except subprocess.TimeoutExpired:
                        observation.update(seconds=time.monotonic() - ocr_start,
                                           status="deadline" if time.monotonic() >= deadline else "engine-timeout")
                        break
                    lines = ocr_lines(result.stdout)
                    text = " ".join(line["text"] for line in lines)
                    matched = bool(check(lines) if check else re.search(pattern, text))
                    observation.update(seconds=time.monotonic() - ocr_start, status="matched" if matched else "unmatched",
                                       text=text, lines=lines)
                    if matched:
                        break
                streak = streak + 1 if matched else 0
                if streak >= consecutive:
                    retain("matched")
                    return lines
                time.sleep(min(0.3, max(0, deadline - time.monotonic())))
            raise TimeoutError(f"Visible text deadline ({timeout}s): {pattern}")
        except Exception as error:
            details["error"] = str(error)
            if isinstance(error, subprocess.CalledProcessError):
                details.update(returncode=error.returncode, stderr=str(error.stderr))
                status = "command-error"
            elif isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
                status = "deadline" if time.monotonic() >= deadline else "command-timeout"
            else:
                status = "error"
            try:
                retain(status)
            except Exception as collection_error:
                error.add_note("Collecting OCR evidence: " + str(collection_error))
            if status == "deadline":
                raise TimeoutError(f"Visible text deadline ({timeout}s): {pattern}") from error
            raise


def qt_password_focus(machine, pid, deadline):
    last = ""
    while time.monotonic() < deadline:
        text = machine.succeed("journalctl -b _PID=" + pid + " --no-pager -o cat", timeout=remaining(deadline))
        changes = [line for line in text.splitlines() if "activeFocusItem" in line
                   and (" -> " in line or " remains " in line)]
        if changes:
            last = re.split(r" -> | remains ", changes[-1])[-1]
            if re.search(r"(?:Password|Text)(?:Field|Input)", last):
                return
        time.sleep(0.1)
    raise AssertionError("Password control has no active focus: " + last)


def login(machine, *, screenshot=None):
    """Authenticate through SDDM so the real PAM wallet lifecycle runs."""
    from datetime import timedelta
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_unit("home-manager-desktop.service")
    # SDDM registers a view even when a QML error sends it to the embedded theme.
    pid = machine.wait_until_succeeds(
        "pid=$(pgrep -u sddm -n -f sddm-greeter) && "
        "journalctl -b _PID=\"$pid\" --no-pager -o cat | grep -F 'Adding view for' >/dev/null && "
        "echo \"$pid\"",
        timeout=60,
    ).strip()
    journal = machine.succeed(f"journalctl -b _PID={pid} --no-pager -o cat", timeout=10)
    if "Fallback to embedded theme" in journal or not re.search(r"Loading file:.*/breeze/+Main\.qml\b", journal):
        raise AssertionError(f"SDDM greeter {pid} could not display Breeze:\n{journal}")
    # The selected account stays legible across greeter sizes; the password
    # placeholder is small and low contrast in Breeze.
    visible(machine, r"(?i)\bdesktop\b", timeout=90, region=(0.25, 0.15, 0.5, 0.7))
    if screenshot is not None:
        machine.screenshot(screenshot)
    deadline = time.monotonic() + 60
    with machine.input_lock, machine.action(deadline):
        qt_password_focus(machine, pid, deadline)
        delay = timedelta(milliseconds=150)
        machine.send_key("ctrl-u", delay=delay)
        machine.send_chars("synthetic-fixture-only", delay=delay)
        machine.send_key("ret", delay=delay)
