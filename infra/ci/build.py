#!/usr/bin/env python3
"""Build evaluated derivations by execution group, classify sources, and collect VM evidence."""

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

try:
    from .report import load_manifest, record, utc_now
except ImportError:
    from report import load_manifest, record, utc_now


# Nix internal-json activity types (src/libutil/include/nix/util/logging.hh).
BUILD_GROUP, BUILD, SUBSTITUTE = 104, 105, 108
PROGRESS = 105


def valid_paths(paths):
    if not paths:
        return set()
    result = subprocess.run(
        ["nix-store", "--check-validity", "--print-invalid", *paths],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return set(paths) - set(result.stdout.splitlines())


def collect_vm_evidence(entries, state, context):
    """Copy guest screenshots, OCR JSON, and diagnostics from realized/retained VM outputs."""
    state = Path(state)
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
                record(
                    state,
                    {
                        **context,
                        "kind": "evidence-missing",
                        "name": entry["name"],
                        "output": output,
                    },
                )
                print(f"{entry['name']} evidence output unavailable: {output}", flush=True)
        if destination.exists():
            for parent in destination.parents:
                if parent == state:
                    break
                parent.chmod(0o755)
            for path in (destination, *destination.rglob("*")):
                if not path.is_symlink():
                    path.chmod(0o755 if path.is_dir() else 0o644)
        files = sum(path.is_file() for path in destination.rglob("*")) if destination.exists() else 0
        if files:
            record(
                state,
                {
                    **context,
                    "kind": "vm-evidence",
                    "name": entry["name"],
                    "path": str(destination.relative_to(state)),
                    "files": files,
                },
            )
            print(f"{entry['name']} evidence: {destination} ({files} files)", flush=True)


def run_build(
    entries,
    *,
    state,
    phase,
    pass_name="candidate",
    jobs=None,
    kvm=False,
    vm_mode=None,
    github_actions=False,
):
    """Execute one build group, stream Nix internal-json events, and classify target outcomes."""
    state = Path(state)
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
    present_before = valid_paths(paths)
    active, activities, build_groups = {}, [], set()
    command = ["nix", "build", "--no-link", "--print-build-logs", "--keep-going"]
    hook = state / "cache" / "post-build-hook"
    if hook.exists():
        command += ["--option", "post-build-hook", str(hook.resolve())]
    if kvm:
        command += ["--option", "system-features", "nixos-test benchmark big-parallel kvm"]
    has_vm = vm_mode is not None or any(entry.get("vm") for entry in entries)
    if has_vm:
        command += ["--keep-failed"]
    if jobs is not None:
        command += ["--max-jobs", str(jobs)]
    command += [entry["drv"] + "^*" for entry in entries]

    collection_error = None
    first_error = None

    def report_error(message, now):
        nonlocal first_error
        if first_error is not None:
            return
        message = re.sub(r"\x1b\[[0-9;]*m", "", message)
        first_error = {
            **context,
            "kind": "build-error",
            "time": utc_now(),
            "seconds": now - start,
            "message": message,
            "log": str(log_path),
        }
        record(state, first_error)
        if github_actions:
            escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print("::error::" + escaped, file=sys.stderr, flush=True)

    def consume(line):
        event = json.loads(line)
        now = time.monotonic()
        if event["action"] == "start" and event.get("type") == BUILD_GROUP:
            build_groups.add(event["id"])
        elif (
            event["action"] == "result"
            and event.get("type") == PROGRESS
            and event["id"] in build_groups
            and event["fields"][3] > 0
        ):
            report_error(
                f"Nix reported a failed build in {pass_name}/{phase}; independent builds continue. Log: {log_path}",
                now,
            )
        elif event["action"] == "start" and event.get("type") in (BUILD, SUBSTITUTE):
            activity = {"type": event["type"], "path": event["fields"][0], "start": now}
            active[event["id"]] = activity
            activities.append(activity)
        elif event["action"] == "stop" and event["id"] in active:
            active.pop(event["id"])["stop"] = now
        elif event["action"] == "msg" and event.get("level") == 0:
            message = re.sub(r"\x1b\[[0-9;]*m", "", event.get("msg", ""))
            if "raw_msg" in event or message.startswith("error:"):
                report_error(event.get("raw_msg", message), now)

    with tempfile.NamedTemporaryFile(dir=state, prefix="nix-events-", suffix=".jsonl") as log:
        with Path(log.name).open() as stream:
            relay = subprocess.Popen(["tee", str(console_log)], stdin=subprocess.PIPE)
            process = None
            pending = ""
            try:
                process = subprocess.Popen(
                    [*command, "--json-log-path", log.name],
                    stdout=relay.stdin,
                    stderr=subprocess.STDOUT,
                )
                relay.stdin.close()
                while True:
                    finished = process.poll() is not None
                    pending += stream.read()
                    lines = pending.split("\n")
                    pending = lines.pop()
                    for line in lines:
                        if line.strip():
                            consume(line)
                    if finished:
                        break
                    time.sleep(0.05)
                returncode = process.wait()
                if returncode:
                    report_error(
                        f"Nix exited with status {returncode} in {pass_name}/{phase}. Log: {log_path}",
                        time.monotonic(),
                    )
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
                    try:
                        vm_entries = [
                            {**entry, "vm": True} if vm_mode is not None else entry
                            for entry in entries
                        ]
                        collect_vm_evidence(vm_entries, state, context)
                    except Exception as error:
                        collection_error = error
                        record(state, {**context, "kind": "evidence-error", "error": str(error)})
                        print(f"VM evidence collection failed: {error}", flush=True)

    end = time.monotonic()
    realized = valid_paths(paths)
    batch = {
        **context,
        "kind": "build",
        "started": started,
        "seconds": end - start,
        "returncode": returncode,
        "command": command,
        "log": str(log_path),
    }
    if first_error:
        batch["afterErrorSeconds"] = batch["seconds"] - first_error["seconds"]
    if collection_error:
        batch["evidenceError"] = str(collection_error)
    if returncode < 0:
        batch["signal"] = signal.Signals(-returncode).name

    for activity in activities:
        record(
            state,
            {
                **context,
                "kind": "activity",
                "source": "build" if activity["type"] == BUILD else "restore",
                "path": activity["path"],
                "finished": "stop" in activity,
                "seconds": activity.get("stop", end) - activity["start"],
            },
        )

    any_dependency_built = any(a["type"] == BUILD for a in activities)
    for entry in entries:
        outputs_set = set(entry["outputs"])
        all_realized = outputs_set <= realized
        built = [a for a in activities if a["type"] == BUILD and a["path"] == entry["drv"]]
        restored = [a for a in activities if a["type"] == SUBSTITUTE and a["path"] in outputs_set]

        if all_realized:
            if built:
                source = "executed"
            elif restored:
                source = "cache restored"
            elif outputs_set <= present_before:
                source = "local reuse"
            elif returncode == 0:
                source = "concurrent reuse"
            else:
                source = "failed"
        else:
            if built or restored or not any_dependency_built:
                source = "failed"
            else:
                # Prerequisite dependency failed before this derivation started building.
                source = "skipped"

        target_success = bool(all_realized and (returncode == 0 or built or restored or outputs_set <= present_before))
        if not all_realized:
            target_success = False

        result = {
            **context,
            "kind": "target",
            **entry,
            **({"vm": True} if vm_mode is not None else {}),
            "source": source,
            "success": target_success,
            "buildSeconds": sum(a.get("stop", end) - a["start"] for a in built) if built else None,
            "restoreSeconds": sum(a.get("stop", end) - a["start"] for a in restored) if restored else None,
        }
        record(state, result)

    record(state, batch)
    if returncode:
        reason = batch.get("signal", f"exit {returncode}")
        error = RuntimeError(f"{pass_name}/{phase}: nix build failed ({reason}); see the diagnostics artifact")
        if collection_error:
            error.add_note("Collecting build diagnostics: " + str(collection_error))
        raise error
    if collection_error:
        raise collection_error


def build_group(*, state, group_name, pass_name="candidate", jobs=None, github_actions=False):
    state = Path(state).resolve()
    manifest = load_manifest(state)
    group = next((g for g in manifest.get("groups", []) if g["name"] == group_name), None)
    if group is None:
        available = ", ".join(g["name"] for g in manifest.get("groups", [])) or "(none)"
        raise RuntimeError(f"Unknown build group '{group_name}'; available groups: {available}")
    entries = group.get("entries", [])
    effective_jobs = jobs if jobs is not None else group.get("maxJobs")
    kvm = bool(group.get("kvm", False))
    vm_mode = group.get("vm")
    run_build(
        entries,
        state=state,
        phase=group_name,
        pass_name=pass_name,
        jobs=effective_jobs,
        kvm=kvm,
        vm_mode=vm_mode,
        github_actions=github_actions,
    )
