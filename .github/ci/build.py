#!/usr/bin/env python3
"""Build prepared derivations in resource groups and time actual Nix activities."""

import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from report import record, utc_now


# Nix 2.34's internal-json activity types (logging.hh).
BUILD, SUBSTITUTE = 105, 108


def valid_paths(paths):
    if not paths:
        return set()
    result = subprocess.run(["nix-store", "--check-validity", "--print-invalid", *paths],
                            check=True, text=True, stdout=subprocess.PIPE)
    return set(paths) - set(result.stdout.splitlines())


def collect_vm_evidence(entries, state, phase, pass_name):
    """Native VM builders put diagnostics in $out even when assertions fail."""
    for entry in entries:
        if not entry.get("vm"):
            continue
        destination = state / "vm" / pass_name / entry["name"]
        for output in entry["outputs"]:
            source = Path(output)
            if source.is_dir():
                shutil.copytree(source, destination / source.name, symlinks=True, dirs_exist_ok=True)
            elif source.exists():
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination / source.name, follow_symlinks=False)
            else:
                record(state, {"kind": "evidence-missing", "pass": pass_name, "phase": phase,
                               "name": entry["name"], "output": output})
                print(f"{entry['name']} evidence output unavailable: {output}", flush=True)
        if destination.exists():
            record(state, {"kind": "vm-evidence", "pass": pass_name, "phase": phase,
                           "name": entry["name"], "path": str(destination.relative_to(state))})
            print(f"{entry['name']} evidence: {destination}", flush=True)


def run_build(entries, *, state, phase, pass_name="candidate", jobs=None):
    """Keep ordinary Nix logs; consume its separate JSON stream while it runs."""
    if not entries:
        return
    state.mkdir(parents=True, exist_ok=True)
    paths = [path for entry in entries for path in entry["outputs"]]
    present = valid_paths(paths)
    active, activities = {}, []
    started, start = utc_now(), time.monotonic()
    command = ["nix", "build", "--no-link", "--print-build-logs", "--keep-going"]
    has_vm = any(entry.get("vm") for entry in entries)
    collection_error = None
    if has_vm:
        # Nix manages build directories and access for its build users.
        command += ["--keep-failed"]
    if jobs is not None:
        command += ["--max-jobs", str(jobs)]
    command += [entry["drv"] + "^*" for entry in entries]

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
                if has_vm:
                    # Collect declared outputs after Nix exits, including
                    # diagnostics written by a failed VM builder.
                    try:
                        collect_vm_evidence(entries, state, phase, pass_name)
                    except Exception as error:
                        collection_error = error
                        record(state, {"kind": "evidence-error", "pass": pass_name,
                                       "phase": phase, "error": str(error)})
                        print(f"VM evidence collection failed: {error}", flush=True)

    end = time.monotonic()
    realized = valid_paths(paths)
    batch = {"kind": "build", "pass": pass_name, "phase": phase, "started": started,
             "seconds": end - start, "returncode": returncode, "command": command}
    if returncode < 0:
        batch["signal"] = signal.Signals(-returncode).name
    record(state, batch)
    for activity in activities:
        record(state, {"kind": "activity", "pass": pass_name, "phase": phase,
                       "source": "build" if activity["type"] == BUILD else "restore",
                       "path": activity["path"], "finished": "stop" in activity,
                       "seconds": activity.get("stop", end) - activity["start"]})
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
        error = RuntimeError(f"{pass_name}/{phase}: nix build failed ({reason}); see the diagnostics artifact")
        if collection_error:
            error.add_note("Collecting VM evidence: " + str(collection_error))
        raise error
    if collection_error:
        raise collection_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", help="group in the evaluated build inventory")
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--pass-name", default="candidate")
    parser.add_argument("--jobs", type=int, help="override Nix concurrency for a VM group")
    args = parser.parse_args()
    policy = json.loads((args.state / "policy.json").read_text())
    run_build(policy["builds"][args.group], state=args.state, phase=args.group,
              pass_name=args.pass_name, jobs=args.jobs)


if __name__ == "__main__":
    main()
