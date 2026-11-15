#!/usr/bin/env python3
"""Build prepared derivations in resource groups and time actual Nix activities."""

import argparse
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from report import record, utc_now


# Nix's internal-json types (src/libutil/include/nix/util/logging.hh).
BUILD_GROUP, BUILD, SUBSTITUTE = 104, 105, 108
PROGRESS = 105


def valid_paths(paths):
    if not paths:
        return set()
    result = subprocess.run(["nix-store", "--check-validity", "--print-invalid", *paths],
                            check=True, text=True, stdout=subprocess.PIPE)
    return set(paths) - set(result.stdout.splitlines())


def collect_vm_evidence(entries, state, context):
    """Collect files explicitly emitted by test scripts into their outputs."""
    for entry in entries:
        if not entry.get("vm"):
            continue
        destination = state / "vm" / context["pass"] / entry["name"] / context["attempt"]
        for output in entry["outputs"]:
            source = Path(output)
            if source.is_dir():
                shutil.copytree(source, destination / source.name, symlinks=True, dirs_exist_ok=True)
            elif source.exists():
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination / source.name, follow_symlinks=False)
            else:
                record(state, {**context, "kind": "evidence-missing",
                               "name": entry["name"], "output": output})
                print(f"{entry['name']} evidence output unavailable: {output}", flush=True)
        files = sum(path.is_file() for path in destination.rglob("*"))
        if files:
            record(state, {**context, "kind": "vm-evidence",
                           "name": entry["name"], "path": str(destination.relative_to(state)), "files": files})
            print(f"{entry['name']} evidence: {destination} ({files} files)", flush=True)


def run_build(entries, *, state, phase, pass_name="candidate", jobs=None, github_actions=False):
    """Keep ordinary Nix logs; consume its separate JSON stream while it runs."""
    if not entries:
        return
    state.mkdir(parents=True, exist_ok=True)
    context = {"pass": pass_name, "phase": phase, "attempt": uuid.uuid4().hex}
    log_path = Path("logs") / pass_name / phase / (context["attempt"] + ".log")
    console_log = state / log_path
    console_log.parent.mkdir(parents=True, exist_ok=True)
    started, start = utc_now(), time.monotonic()
    record(state, {**context, "kind": "build-start", "started": started, "log": str(log_path)})
    paths = [path for entry in entries for path in entry["outputs"]]
    present = valid_paths(paths)
    active, activities, build_groups = {}, [], set()
    command = ["nix", "build", "--no-link", "--print-build-logs", "--keep-going"]
    hook = state / "cache" / "post-build-hook"
    if hook.exists():
        command += ["--option", "post-build-hook", str(hook.resolve())]
    has_vm = any(entry.get("vm") for entry in entries)
    collection_error = None
    first_error = None
    if has_vm:
        # Nix manages build directories and access for its build users.
        command += ["--keep-failed"]
    if jobs is not None:
        command += ["--max-jobs", str(jobs)]
    command += [entry["drv"] + "^*" for entry in entries]

    def report_error(message, now):
        nonlocal first_error
        if first_error is not None:
            return
        message = re.sub(r"\x1b\[[0-9;]*m", "", message)
        first_error = {**context, "kind": "build-error", "time": utc_now(),
                       "seconds": now - start, "message": message, "log": str(log_path)}
        record(state, first_error)
        if github_actions:
            # Workflow command data occupies one escaped line.
            escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print("::error::" + escaped, file=sys.stderr, flush=True)

    def consume(line):
        event = json.loads(line)
        now = time.monotonic()
        if event["action"] == "start" and event.get("type") == BUILD_GROUP:
            build_groups.add(event["id"])
        elif (event["action"] == "result" and event.get("type") == PROGRESS
              and event["id"] in build_groups and event["fields"][3] > 0):
            # --keep-going can defer the detailed error until every goal ends.
            # Progress fields are done, expected, running, failed.
            report_error(f"Nix reported a failed build in {pass_name}/{phase}; "
                         f"independent builds continue. Log: {log_path}", now)
        elif event["action"] == "start" and event.get("type") in (BUILD, SUBSTITUTE):
            activity = {"type": event["type"], "path": event["fields"][0], "start": now}
            active[event["id"]] = activity
            activities.append(activity)
        elif event["action"] == "stop" and event["id"] in active:
            active.pop(event["id"])["stop"] = now
        elif event["action"] == "msg" and event.get("level") == 0:
            report_error(event.get("raw_msg", event.get("msg", "Nix build error")), now)

    # Each Nix process owns a separate log. It is read continuously so elapsed
    # times use the local monotonic clock, rather than parsing console timestamps.
    with tempfile.NamedTemporaryFile(dir=state, prefix="nix-events-", suffix=".jsonl") as log:
        with Path(log.name).open() as stream:
            relay = subprocess.Popen(["tee", str(console_log)], stdin=subprocess.PIPE)
            process = None
            pending = ""
            try:
                process = subprocess.Popen([*command, "--json-log-path", log.name],
                                           stdout=relay.stdin, stderr=subprocess.STDOUT)
                relay.stdin.close()
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
                relay.stdin.close()
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                try:
                    relay_status = relay.wait(timeout=10)
                    if relay_status:
                        raise RuntimeError(f"Build log capture exited with status {relay_status}: {log_path}")
                except Exception as error:
                    relay.kill()
                    relay.wait()
                    collection_error = error
                    record(state, {**context, "kind": "evidence-error", "error": str(error)})
                    print(f"Build log capture failed: {error}", flush=True)
                if has_vm:
                    # Outputs can contain screenshots and files copied by the test.
                    try:
                        collect_vm_evidence(entries, state, context)
                    except Exception as error:
                        collection_error = error
                        record(state, {**context, "kind": "evidence-error", "error": str(error)})
                        print(f"VM evidence collection failed: {error}", flush=True)

    end = time.monotonic()
    realized = valid_paths(paths)
    batch = {**context, "kind": "build", "started": started,
             "seconds": end - start, "returncode": returncode, "command": command, "log": str(log_path)}
    if first_error:
        batch["afterErrorSeconds"] = batch["seconds"] - first_error["seconds"]
    if collection_error:
        batch["evidenceError"] = str(collection_error)
    if returncode < 0:
        batch["signal"] = signal.Signals(-returncode).name
    for activity in activities:
        record(state, {**context, "kind": "activity",
                       "source": "build" if activity["type"] == BUILD else "restore",
                       "path": activity["path"], "finished": "stop" in activity,
                       "seconds": activity.get("stop", end) - activity["start"]})
    for entry in entries:
        built = [a for a in activities if a["type"] == BUILD and a["path"] == entry["drv"]]
        restored = [a for a in activities if a["type"] == SUBSTITUTE and a["path"] in entry["outputs"]]
        source = ("built" if built else "local" if set(entry["outputs"]) <= present
                  else "substituted" if restored else "unknown")
        result = {**context, "kind": "target", **entry,
                  "source": source, "success": set(entry["outputs"]) <= realized,
                  "buildSeconds": sum(a.get("stop", end) - a["start"] for a in built) if built else None,
                  "restoreSeconds": sum(a.get("stop", end) - a["start"] for a in restored) if restored else None}
        record(state, result)
    # Completion follows all target records. An interrupted writer leaves a
    # started attempt, which cannot satisfy verification with an older result.
    record(state, batch)
    if returncode:
        reason = batch.get("signal", f"exit {returncode}")
        error = RuntimeError(f"{pass_name}/{phase}: nix build failed ({reason}); see the diagnostics artifact")
        if collection_error:
            error.add_note("Collecting build diagnostics: " + str(collection_error))
        raise error
    if collection_error:
        raise collection_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", help="group in the evaluated build inventory")
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--pass-name", default="candidate")
    parser.add_argument("--jobs", type=int, help="override Nix concurrency for a VM group")
    parser.add_argument("--github-actions", action="store_true", help="annotate the first Nix error immediately")
    args = parser.parse_args()
    policy = json.loads((args.state / "policy.json").read_text())
    run_build(policy["builds"][args.group], state=args.state, phase=args.group,
              pass_name=args.pass_name, jobs=args.jobs, github_actions=args.github_actions)


if __name__ == "__main__":
    main()
