#!/usr/bin/env python3
"""Build prepared derivations in resource groups and time actual Nix activities."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from scripts.ci.report import record, utc_now


PHASES = ("dependencies", "vm-network-desktop", "vm-applications-backup", "aggregate")
# Nix 2.34's internal-json activity types (logging.hh).
BUILD, SUBSTITUTE = 105, 108


def valid_paths(paths):
    if not paths:
        return set()
    result = subprocess.run(["nix-store", "--check-validity", "--print-invalid", *paths],
                            check=True, text=True, stdout=subprocess.PIPE)
    return set(paths) - set(result.stdout.splitlines())


def run_build(entries, *, state, phase, pass_name="candidate", jobs=2, cores=2):
    """Keep ordinary Nix logs; consume its separate JSON stream while it runs."""
    if not entries:
        return
    state.mkdir(parents=True, exist_ok=True)
    paths = [path for entry in entries for path in entry["outputs"]]
    present = valid_paths(paths)
    active, activities = {}, []
    started, start = utc_now(), time.monotonic()
    command = ["nix", "build", "--no-link", "--print-build-logs", "--max-jobs", str(jobs),
               "--cores", str(cores), *[entry["drv"] + "^*" for entry in entries]]

    def consume(line):
        event = json.loads(line)
        now = time.monotonic()
        if event["action"] == "start" and event.get("type") in (BUILD, SUBSTITUTE):
            activity = {"type": event["type"], "path": event["fields"][0], "start": now}
            active[event["id"]] = activity
            activities.append(activity)
        elif event["action"] == "stop" and event["id"] in active:
            active.pop(event["id"])["stop"] = now

    # Each Nix process owns a separate log. It is read continuously so elapsed
    # times use the local monotonic clock, rather than parsing console timestamps.
    with tempfile.NamedTemporaryFile(dir=state, prefix="nix-events-", suffix=".jsonl") as log:
        with Path(log.name).open() as stream:
            process = subprocess.Popen([*command, "--json-log-path", log.name])
            pending = ""
            try:
                while True:
                    finished = process.poll() is not None
                    pending += stream.read()
                    lines = pending.split("\n")
                    pending = lines.pop()
                    for line in lines:
                        consume(line)
                    if finished:
                        break
                    time.sleep(0.05)
                returncode = process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

    end = time.monotonic()
    realized = valid_paths(paths)
    batch = {"kind": "build", "pass": pass_name, "phase": phase, "started": started,
             "seconds": end - start, "returncode": returncode, "command": command}
    if returncode < 0:
        batch["signal"] = signal.Signals(-returncode).name
    record(state, batch)
    for entry in entries:
        built = [a for a in activities if a["type"] == BUILD and a["path"] == entry["drv"]]
        restored = [a for a in activities if a["type"] == SUBSTITUTE and a["path"] in entry["outputs"]]
        source = ("built" if built else "local" if set(entry["outputs"]) <= present
                  else "substituted" if restored else "unknown")
        result = {"kind": "target", "pass": pass_name, "phase": phase, **entry,
                  "source": source, "success": set(entry["outputs"]) <= realized,
                  "buildSeconds": sum(a.get("stop", end) - a["start"] for a in built) if built else None,
                  "restoreSeconds": sum(a.get("stop", end) - a["start"] for a in restored) if restored else None}
        record(state, result)
    if returncode:
        reason = batch.get("signal", f"exit {returncode}")
        raise RuntimeError(f"{pass_name}/{phase}: nix build failed ({reason}); resource evidence is collected at runner finish")


def build_phase(policy, phase, *, state, pass_name="candidate"):
    cpus = len(os.sched_getaffinity(0))
    jobs = min(2, cpus)
    cores = max(1, cpus // jobs)
    if phase == "dependencies":
        # Public test closures may reference payloads we cannot redistribute.
        run_build(policy["builds"]["private"], state=state, phase="private-dependencies",
                  pass_name=pass_name, jobs=jobs, cores=cores)
    run_build(policy["builds"][phase], state=state, phase=phase, pass_name=pass_name,
              jobs=jobs, cores=cores)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=[*PHASES, "all"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--pass-name", default="candidate")
    args = parser.parse_args()
    policy = json.loads((args.state / "policy.json").read_text())
    for phase in PHASES if args.phase == "all" else [args.phase]:
        build_phase(policy, phase, state=args.state, pass_name=args.pass_name)


if __name__ == "__main__":
    main()
