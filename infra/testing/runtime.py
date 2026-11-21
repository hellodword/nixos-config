"""Bounded failure evidence collection and guest shutdown for NixOS QEMU VM tests."""

from contextlib import contextmanager
from datetime import timedelta
import json
from pathlib import Path
import subprocess
import time


def collect_failure(error, captures=(), screenshots=()):
    deadline = time.monotonic() + 60
    results = []
    for guest, name, command in captures:
        try:
            if not guest.connected:
                raise RuntimeError("guest control shell is unavailable; retain the driver serial log")
            per_capture = (60 - (20 if screenshots else 0)) / max(1, len(captures))
            budget = min(10, per_capture, deadline - time.monotonic())
            if budget <= 0:
                raise TimeoutError("failure evidence budget exhausted")
            status, output = guest.execute("set +e; " + command, timeout=budget)
            destination = Path(guest.out_dir) / "diagnostics"
            destination.mkdir(exist_ok=True)
            path = destination / (guest.name + "-" + name + ".log")
            path.write_text(output)
            results.append({"guest": guest.name, "capture": name, "status": status, "path": str(path)})
        except Exception as failure:
            error.add_note(f"Collecting {guest.name}/{name}: {failure}")
            results.append({"guest": guest.name, "capture": name, "error": str(failure)})
    for guest in screenshots:
        try:
            budget = min(20, deadline - time.monotonic())
            if budget <= 0:
                raise TimeoutError("failure evidence budget exhausted")
            guest.screenshot(guest.name + "-failure", timeout=budget)
        except Exception as failure:
            error.add_note(f"Collecting {guest.name}/screenshot: {failure}")
    print(json.dumps({"failure": str(error), "evidence": results}), flush=True)


def release_guest(guest, *, crash=False):
    if not guest.booted:
        return
    try:
        if guest.connected and not crash:
            guest.execute(
                "systemctl poweroff --no-block",
                timeout=10,
                check_return=False,
                check_output=False,
            )
        else:
            previous = guest.monitor.gettimeout()
            try:
                guest.monitor.settimeout(10)
                guest.send_monitor_command("quit")
            finally:
                guest.monitor.settimeout(previous)
        guest.wait_for_shutdown(timeout=timedelta(seconds=120))
    except Exception:
        guest.process.terminate()
        try:
            guest.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            guest.process.kill()
            guest.process.wait(timeout=10)
        raise


@contextmanager
def scenario(guests, captures, screenshots=()):
    failure = None
    try:
        yield
    except Exception as error:
        failure = error
        collect_failure(
            error,
            captures() if callable(captures) else captures,
            screenshots() if callable(screenshots) else screenshots,
        )
        raise
    finally:
        errors = []
        for guest in reversed(guests):
            try:
                release_guest(guest)
            except Exception as error:
                errors.append(f"Releasing {guest.name}: {error}")
        if errors:
            if failure is not None:
                for error in errors:
                    failure.add_note(error)
            else:
                raise RuntimeError("; ".join(errors))
