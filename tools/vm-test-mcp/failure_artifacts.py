"""Carry synthetic failure screenshots through executors that retain only logs."""
import base64
from pathlib import Path
import shlex
import tempfile


def emit_frame(machine, label, guest_path=None):
    if guest_path:
        status, frame = machine.execute("test -f " + shlex.quote(guest_path) + " && base64 -w0 " + shlex.quote(guest_path))
        if status == 0:
            print(label + "=" + frame.strip())
            return
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "failure.png"
        machine.screenshot(str(path))
        print(label + "=" + base64.b64encode(path.read_bytes()).decode())
