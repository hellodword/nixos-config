#!/usr/bin/env python3
"""Record CI timings and host/cgroup resources, verify manifest results, and render summaries."""

from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import time


SOURCE_LABELS = {
    "executed": "executed",
    "local reuse": "local reuse",
    "concurrent reuse": "concurrent reuse",
    "cache restored": "cache restored",
    "skipped": "skipped",
    "failed": "failed",
}


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def record(state, event, filename="timings.jsonl"):
    state = Path(state)
    state.mkdir(parents=True, exist_ok=True)
    with (state / filename).open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(event) + "\n")
        stream.flush()


def cgroup_path(pid):
    if pid is None or pid <= 0:
        return None
    proc_cgroup = Path(f"/proc/{pid}/cgroup")
    if not proc_cgroup.exists():
        return None
    for line in proc_cgroup.read_text().splitlines():
        if line.startswith("0::"):
            candidate = Path("/sys/fs/cgroup") / line.split(":", 2)[2].lstrip("/")
            return candidate if candidate.exists() else None
    return None


def resource_sample(state, cgroup=None, previous_cpu=None):
    state = Path(state)
    memory = {
        line.split()[0].rstrip(":"): int(line.split()[1]) * 1024
        for line in Path("/proc/meminfo").read_text().splitlines()
        if len(line.split()) == 3
    }
    cpu = [int(value) for value in Path("/proc/stat").read_text().splitlines()[0].split()[1:9]]
    total, idle = sum(cpu), cpu[3] + cpu[4]
    state.mkdir(parents=True, exist_ok=True)
    event = {
        "time": utc_now(),
        "memoryTotal": memory["MemTotal"],
        "memoryAvailable": memory["MemAvailable"],
        "swapTotal": memory["SwapTotal"],
        "swapUsed": memory["SwapTotal"] - memory["SwapFree"],
        "diskFree": shutil.disk_usage(state).free,
    }
    if previous_cpu and total > previous_cpu[0]:
        event["cpuPercent"] = 100 * (1 - (idle - previous_cpu[1]) / (total - previous_cpu[0]))
    if cgroup is not None:
        for filename, key in (
            ("memory.current", "containerMemory"),
            ("memory.peak", "containerMemoryPeak"),
            ("memory.swap.current", "containerSwap"),
        ):
            path = cgroup / filename
            if path.exists():
                try:
                    event[key] = int(path.read_text().strip())
                except ValueError:
                    pass
        path = cgroup / "memory.events"
        if path.exists():
            event["memoryEvents"] = {
                key: int(value)
                for key, value in (line.split() for line in path.read_text().splitlines() if len(line.split()) == 2)
            }
    record(state, event, "resources.jsonl")
    return total, idle


def monitor(state, pid=None):
    state = Path(state)
    cgroup = cgroup_path(pid)
    previous = None
    while True:
        previous = resource_sample(state, cgroup, previous)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (state / "monitor.stop").exists():
                return
            time.sleep(1)


def read_records(path):
    path = Path(path)
    if not path.exists():
        return []
    return [
        json.loads(line)
        for line in path.read_text().splitlines(keepends=True)
        if line.endswith("\n") and line.strip()
    ]


def has_manifest(state):
    return (Path(state) / "manifest.json").exists()


def load_manifest(state):
    candidate = Path(state) / "manifest.json"
    if candidate.exists():
        return json.loads(candidate.read_text())
    return {"groups": []}


def duration(seconds):
    if seconds is None:
        return "—"
    return f"{seconds / 60:.2f} min"


def _target_identity(attempt, item):
    return (attempt, item["drv"], tuple(sorted(item.get("outputs") or ())))


def evaluate_group_targets(manifest, events, pass_name, *, vm_only=False, required_only=False):
    scoped = [event for event in events if event.get("pass") == pass_name]
    attempts = {event["phase"]: event["attempt"] for event in scoped if event["kind"] == "build-start"}
    completed = {event["attempt"]: event for event in scoped if event["kind"] == "build"}
    targets = {
        _target_identity(event["attempt"], event): event
        for event in scoped
        if event["kind"] == "target" and "drv" in event
    }

    results = []
    for group in manifest.get("groups", []):
        group_name = group["name"]
        group_required = group.get("required", True)
        for item in group.get("entries", []):
            is_vm = bool(item.get("vm") or group.get("vm"))
            is_required = bool(item.get("required", group_required))
            if vm_only and not is_vm:
                continue
            if required_only and not is_required:
                continue
            attempt = attempts.get(group_name)
            if attempt is None:
                results.append({
                    **item,
                    "phase": group_name,
                    "pass": pass_name,
                    "attempt": None,
                    "required": is_required,
                    "vm": is_vm,
                    "success": False,
                    "source": "skipped",
                    "buildSeconds": None,
                    "restoreSeconds": None,
                })
                continue
            batch = completed.get(attempt, {})
            target = targets.get(_target_identity(attempt, item), {})
            matches = (
                target.get("drv") == item["drv"]
                and set(target.get("outputs", [])) == set(item["outputs"])
            )
            raw_source = target.get("source", "failed") if matches else "failed"
            canonical_source = SOURCE_LABELS.get(raw_source, "failed")
            fresh_or_clean = (
                batch.get("returncode") == 0
                or canonical_source in ("executed", "cache restored")
            )
            success = bool(
                matches
                and target.get("success", False)
                and "returncode" in batch
                and fresh_or_clean
                and not batch.get("evidenceError")
            )
            if not success and canonical_source not in ("skipped", "failed"):
                canonical_source = "failed"
            results.append({
                **item,
                "phase": group_name,
                "pass": pass_name,
                "attempt": attempt,
                "required": is_required,
                "vm": is_vm,
                "success": success,
                "source": canonical_source,
                "buildSeconds": target.get("buildSeconds") if matches else None,
                "restoreSeconds": target.get("restoreSeconds") if matches else None,
            })
    return results


def current_vm_results(manifest, events, pass_name):
    return evaluate_group_targets(manifest, events, pass_name, vm_only=True)


def verify_results(state, pass_name="candidate"):
    state = Path(state)
    if not has_manifest(state):
        raise RuntimeError(f"CI manifest not found in {state}")
    manifest = load_manifest(state)
    events = read_records(state / "timings.jsonl")
    required_targets = evaluate_group_targets(manifest, events, pass_name, required_only=True)
    if not required_targets:
        raise RuntimeError(f"Manifest in {state} defines no required CI targets")
    completed = {
        event["attempt"]: event
        for event in events
        if event.get("pass") == pass_name and event["kind"] == "build"
    }
    name_counts = {}
    for item in required_targets:
        name_counts[item["name"]] = name_counts.get(item["name"], 0) + 1

    def label_for(item):
        if name_counts.get(item["name"], 0) > 1 and item.get("drv"):
            return f"{item['name']} ({Path(item['drv']).name[:12]})"
        return item["name"]

    incomplete = sorted({
        label_for(item)
        for item in required_targets
        if not item["success"] or completed.get(item["attempt"], {}).get("returncode") != 0
    })
    record(
        state,
        {
            "kind": "verification",
            "pass": pass_name,
            "expected": len(required_targets),
            "incomplete": incomplete,
        },
    )
    if incomplete:
        raise RuntimeError("Required CI targets incomplete: " + ", ".join(incomplete))
    print(f"{pass_name}: all {len(required_targets)} required targets succeeded", flush=True)


def render(state):
    state = Path(state)
    events = read_records(state / "timings.jsonl")
    lines = ["## Nix build and VM results"]
    phases = [event for event in events if event["kind"] == "phase"]
    if phases:
        lines += [
            "",
            "### Preparation and publication",
            "",
            "| Phase | Exit status | Wall time |",
            "| --- | --- | --- |",
        ]
        for event in phases:
            lines.append(f"| {event['phase']} | {event['returncode']} | {duration(event['seconds'])} |")

    evaluations = [event for event in events if event["kind"] == "evaluation"]
    if evaluations:
        lines += [
            "",
            "### Inventory evaluation",
            "",
            "| Job | Result | Evaluation time |",
            "| --- | --- | --- |",
        ]
        for event in evaluations:
            lines.append(
                f"| {event['name']} | {'success' if event['success'] else 'failed'} | {duration(event['seconds'])} |"
            )

    cache_events = [
        event
        for event in events
        if event["kind"] in ("publication", "cache-query", "cache-upload", "cache-checkpoint", "cache-error")
    ]
    if cache_events:
        lines += [
            "",
            "### Cache publication",
            "",
            "NAR sizes are uncompressed. Upstream hits cover read-only substituters; target hits already exist in the destination cache.",
            "",
            "| Phase | Candidates | Excluded | Upstream hits | Target hits | Uploaded | NAR GiB | Queries | Uploads | Checkpoint wait | Result |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for phase in dict.fromkeys(event.get("phase", "publication") for event in cache_events):
            selected = [e for e in cache_events if e.get("phase", "publication") == phase]
            publications = [e for e in selected if e["kind"] == "publication"]
            queries = [e for e in selected if e["kind"] == "cache-query"]
            uploads = [e for e in selected if e["kind"] == "cache-upload"]
            checkpoints = [e for e in selected if e["kind"] == "cache-checkpoint"]
            candidates_total = sum(e.get("candidates", 0) for e in publications)
            excluded_total = sum(e.get("excluded", 0) for e in publications)
            upstream_total = sum(e.get("upstreamHits", 0) for e in publications)
            target_total = sum(e.get("targetHits", 0) for e in publications)
            successful = [e for e in uploads if e["returncode"] == 0]
            failed_any = (
                any(e["returncode"] for e in uploads + checkpoints)
                or any(e["kind"] == "cache-error" for e in selected)
                or any(e.get("queryFailures", 0) > 0 for e in publications)
            )
            status = "failed" if failed_any else ("complete" if checkpoints or uploads else "verified")
            wait = sum(e["seconds"] for e in checkpoints) if checkpoints else None
            lines.append(
                f"| {phase} | {candidates_total} | {excluded_total} | {upstream_total} | "
                f"{target_total} | {sum(e['paths'] for e in successful)} | "
                f"{sum(e['narBytes'] for e in successful) / 1024 ** 3:.3f} | "
                f"{duration(sum(e['seconds'] for e in queries))} | "
                f"{duration(sum(e['seconds'] for e in uploads))} | {duration(wait)} | {status} |"
            )
        for event in cache_events:
            if event["kind"] == "cache-error":
                lines += ["", f"Publisher failure in {event['phase']}: {event['error']}."]

    builds = [event for event in events if event["kind"] == "build"]
    if builds:
        lines += [
            "",
            "### Nix build groups",
            "",
            "| Revision | Group | Result | Wall time | After first error | Log |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        for event in builds:
            status = "success" if event["returncode"] == 0 else event.get("signal", f"exit {event['returncode']}")
            lines.append(
                f"| {event['pass']} | {event['phase']} | {status} | {duration(event['seconds'])} | "
                f"{duration(event.get('afterErrorSeconds'))} | `{event.get('log', '')}` |"
            )

    completed = {event["attempt"] for event in builds}
    for event in events:
        if event["kind"] == "build-start" and event["attempt"] not in completed:
            lines += [
                "",
                f"Unfinished attempt: {event['pass']}/{event['phase']} "
                f"started at {event['started']} (`{event['attempt']}`); log: `{event.get('log', '')}`.",
            ]
    for event in events:
        if event["kind"] == "build-error":
            lines += [
                "",
                f"First Nix error in {event['pass']}/{event['phase']} at {event['time']}:\n",
                "```text",
                event["message"],
                "```",
            ]

    activities = [event for event in events if event["kind"] == "activity"]
    for source, title in (("build", "Longest builds"), ("restore", "Longest cache restores")):
        selected = [event for event in activities if event["source"] == source]
        if selected:
            lines += [
                "",
                "### " + title,
                "",
                "| Group | Store path | Activity | Elapsed |",
                "| --- | --- | --- | --- |",
            ]
            for event in sorted(selected, key=lambda item: item["seconds"], reverse=True)[:20]:
                status = "ended" if event["finished"] else "unfinished"
                lines.append(
                    f"| {event['phase']} | `{event['path']}` | {status} | {duration(event['seconds'])} |"
                )

    manifest = load_manifest(state)
    passes = list(dict.fromkeys(event["pass"] for event in events if event["kind"] == "build-start"))
    if not passes and any(g.get("vm") for g in manifest.get("groups", [])):
        passes = ["candidate"]
    tests = [result for pass_name in passes for result in current_vm_results(manifest, events, pass_name)]
    if tests:
        lines += [
            "",
            "### VM results",
            "",
            "| Revision | Test | Source | Result | Execution | Restore |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        for event in tests:
            result_label = (
                "success"
                if event["success"]
                else ("skipped" if event["source"] == "skipped" else "failed")
            )
            lines.append(
                f"| {event['pass']} | {event['name']} | {event['source']} | {result_label} | "
                f"{duration(event['buildSeconds'])} | {duration(event['restoreSeconds'])} |"
            )
        expected = {
            item["name"]
            for group in manifest.get("groups", [])
            for item in group.get("entries", [])
            if item.get("vm") or group.get("vm")
        }
        vm_group_names = {
            group["name"]
            for group in manifest.get("groups", [])
            if group.get("vm") or any(item.get("vm") for item in group.get("entries", []))
        }
        for pass_name in dict.fromkeys(event["pass"] for event in tests):
            fresh = {
                event["name"]
                for event in tests
                if event["pass"] == pass_name and event["source"] == "executed" and event["success"]
            }
            seconds = sum(
                event["seconds"]
                for event in builds
                if event["pass"] == pass_name and event["phase"] in vm_group_names
            )
            completeness = (
                "all required VM tests freshly executed"
                if fresh == expected
                else "includes reuse, skipped, or failed tests"
            )
            lines += [
                "",
                f"**{pass_name}:** VM stage wall time {duration(seconds)}; "
                f"{len(fresh)}/{len(expected)} freshly executed ({completeness}).",
            ]

    evidence = [event for event in events if event["kind"] == "vm-evidence"]
    if evidence:
        lines += [
            "",
            "### VM evidence",
            "",
            "| Revision | Group | Test | Files | Evidence |",
            "| --- | --- | --- | --- | --- |",
        ]
        for event in evidence:
            lines.append(
                f"| {event['pass']} | {event['phase']} | {event['name']} | {event.get('files', '—')} | `{event['path']}` |"
            )
    for event in events:
        if event["kind"] == "evidence-missing":
            lines += ["", f"VM output unavailable for {event['pass']}/{event['name']}: `{event['output']}`."]
        if event["kind"] == "evidence-error":
            lines += ["", f"Evidence collection failed for {event['phase']}: {event['error']}."]

    samples = read_records(state / "resources.jsonl")
    lines += ["", "### Runner resources", ""]
    if samples:
        gib = 1024 ** 3
        used = max(sample["memoryTotal"] - sample["memoryAvailable"] for sample in samples)
        lines += [
            f"- Host memory used peak (sampled): {used / gib:.2f} GiB.",
            f"- Host swap used peak (sampled): {max(s['swapUsed'] for s in samples) / gib:.2f} GiB.",
            f"- Minimum disk available (sampled): {min(s['diskFree'] for s in samples) / gib:.2f} GiB.",
        ]
        peaks = [s["containerMemoryPeak"] for s in samples if "containerMemoryPeak" in s]
        if peaks:
            lines.append(f"- Container memory peak (cgroup): {max(peaks) / gib:.2f} GiB.")
        cpus = [s["cpuPercent"] for s in samples if "cpuPercent" in s]
        if cpus:
            lines.append(f"- CPU utilization: mean {sum(cpus) / len(cpus):.1f}%, peak {max(cpus):.1f}% (sampled).")
        counters = [s["memoryEvents"] for s in samples if "memoryEvents" in s]
        if counters:
            killed = counters[-1].get("oom_kill", 0) - counters[0].get("oom_kill", 0)
            lines.append(f"- Container OOM kills during monitoring: {killed}.")
            for key, label in (("max", "Memory limit hits"), ("sock_throttled", "Socket memory throttling events")):
                if any(key in counter for counter in counters):
                    lines.append(f"- {label}: {counters[-1].get(key, 0) - counters[0].get(key, 0)}.")
    else:
        lines.append("Resource samples are unavailable.")

    for filename in ("oom-kernel.log", "oom-userspace.log", "monitor.log"):
        path = state / filename
        if path.exists() and path.read_text().strip() not in ("", "-- No entries --"):
            lines += ["", f"{filename}:", "```text", *path.read_text().splitlines()[-40:], "```"]
    return "\n".join(lines) + "\n"


def run_phase(state, phase, command):
    started, start = utc_now(), time.monotonic()
    result = subprocess.run(command)
    record(
        state,
        {
            "kind": "phase",
            "phase": phase,
            "started": started,
            "seconds": time.monotonic() - start,
            "returncode": result.returncode,
        },
    )
    return result.returncode if result.returncode >= 0 else 128 - result.returncode
