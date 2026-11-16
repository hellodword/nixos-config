"""Observe a real locker's ready FD, preserving xss-lock's sleep inhibitor."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import uuid

kind, binary, *arguments = sys.argv[1:]
state = Path(os.environ["XDG_RUNTIME_DIR"]) / (kind + "-ready.json")
identity = uuid.uuid4().hex


def publish(phase):
    pending = state.with_suffix(".pending")
    pending.write_text(json.dumps({"id": identity, "phase": phase}))
    pending.replace(state)


publish("starting")
reader, writer = os.pipe()
environment = dict(os.environ)
inhibitor = environment.pop("XSS_SLEEP_LOCK_FD", None)
if kind == "swaylock":
    arguments += ["--ready-fd", str(writer)]
else:
    environment["XSS_SLEEP_LOCK_FD"] = str(writer)
process = subprocess.Popen([binary, *arguments], pass_fds=(writer,), env=environment)
os.close(writer)
for signum in (signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, lambda sig, frame: process.send_signal(sig))
try:
    if not select.select([reader], [], [], 120)[0]:
        raise TimeoutError("locker did not report readiness")
    data = os.read(reader, 1)
    if kind == "swaylock" and data != b"\n":
        raise RuntimeError("swaylock exited before locking")
    if process.poll() not in (None, 0):
        raise RuntimeError(f"locker exited with {process.returncode}")
    publish("ready")
finally:
    os.close(reader)
    if inhibitor is not None:
        os.close(int(inhibitor))
sys.exit(process.wait())
