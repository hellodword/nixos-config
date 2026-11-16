"""Run a native VM test and bounded CPU competition in the same CPU set."""
import json
import os
import signal
import subprocess
import sys
from pathlib import Path
import time

cpus = sorted(os.sched_getaffinity(0))[:4]
os.sched_setaffinity(0, cpus)
started = time.monotonic()
load = subprocess.Popen([sys.argv[1], "--cpu", str(len(cpus)), "--cpu-load", "50",
                         "--cpu-load-slice", "100", "--metrics-brief"], start_new_session=True)
test = None
result = None


def interrupted(signum, frame):
    raise InterruptedError(f"CPU pressure run received signal {signum}")


for signum in (signal.SIGTERM, signal.SIGINT):
    signal.signal(signum, interrupted)
try:
    print(json.dumps({"cpuPressure": {"cpus": cpus, "workers": len(cpus), "loadPercent": 50}}), flush=True)
    test = subprocess.Popen(sys.argv[2:], start_new_session=True)
    while test.poll() is None:
        if load.poll() is not None:
            raise RuntimeError(f"CPU load process exited with {load.returncode}")
        time.sleep(0.2)
    result = test.returncode
finally:
    for process in (test, load):
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
    report = {"cpus": cpus, "workers": len(cpus), "loadPercent": 50,
              "seconds": time.monotonic() - started, "returncode": result}
    destination = Path(os.environ["out"])
    destination.mkdir(exist_ok=True)
    (destination / "cpu-pressure.json").write_text(json.dumps(report, indent=2))
sys.exit(result)
