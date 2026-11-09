#!/usr/bin/env python3
"""Record CI timings and host resources, and render the Actions summary."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def record(state, event, filename="timings.jsonl"):
    state.mkdir(parents=True, exist_ok=True)
    with (state / filename).open("a") as stream:
        stream.write(json.dumps(event) + "\n")


def cgroup_path(pid):
    for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines():
        if line.startswith("0::"):
            return Path("/sys/fs/cgroup") / line.split(":", 2)[2].lstrip("/")
    return None


def resource_sample(state, cgroup, previous_cpu=None):
    memory = {line.split()[0].rstrip(":"): int(line.split()[1]) * 1024
              for line in Path("/proc/meminfo").read_text().splitlines() if len(line.split()) == 3}
    # guest and guest_nice are already included in user/nice.
    cpu = [int(value) for value in Path("/proc/stat").read_text().splitlines()[0].split()[1:9]]
    total, idle = sum(cpu), cpu[3] + cpu[4]
    event = {"time": utc_now(), "memoryTotal": memory["MemTotal"],
             "memoryAvailable": memory["MemAvailable"], "swapTotal": memory["SwapTotal"],
             "swapUsed": memory["SwapTotal"] - memory["SwapFree"],
             "diskFree": shutil.disk_usage(state).free}
    if previous_cpu and total > previous_cpu[0]:
        event["cpuPercent"] = 100 * (1 - (idle - previous_cpu[1]) / (total - previous_cpu[0]))
    if cgroup is not None:
        for filename, key in (("memory.current", "containerMemory"), ("memory.peak", "containerMemoryPeak"),
                              ("memory.swap.current", "containerSwap")):
            path = cgroup / filename
            if path.exists():
                event[key] = int(path.read_text())
        path = cgroup / "memory.events"
        if path.exists():
            event["memoryEvents"] = {key: int(value) for key, value in
                                     (line.split() for line in path.read_text().splitlines())}
    record(state, event, "resources.jsonl")
    return total, idle


def monitor(state, pid):
    cgroup = cgroup_path(pid)
    previous = None
    while True:
        previous = resource_sample(state, cgroup, previous)
        # The stop file lets the next Actions step stop this process without
        # signalling a PID that could have been reused after a monitor failure.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (state / "monitor.stop").exists():
                return
            time.sleep(1)


def read_records(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def duration(seconds):
    if seconds is None:
        return "—"
    return f"{seconds / 60:.2f} min"


def render(state):
    events = read_records(state / "timings.jsonl")
    lines = ["## Nix build and VM results"]
    phases = [event for event in events if event["kind"] == "phase"]
    if phases:
        lines += ["", "### Preparation and publication", "",
                  "| Phase | Exit status | Wall time |", "| --- | --- | --- |"]
        for event in phases:
            lines.append(f"| {event['phase']} | {event['returncode']} | {duration(event['seconds'])} |")
    publications = [event for event in events if event["kind"] == "publication"]
    if publications:
        lines += ["", "### Cache publication", "",
                  "Project hits include this run's successful upload receipts. NAR sizes are uncompressed.", "",
                  "| Phase | Candidates | Excluded | Public hits | Project hits | Pending | NAR GiB | Queries | Uploads | Result |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for event in publications:
            queries = [e for e in events if e["kind"] == "cache-query" and e["phase"] == event["phase"]]
            uploads = [e for e in events if e["kind"] == "cache-upload" and e["phase"] == event["phase"]]
            completed = sum(e["paths"] for e in uploads if e["returncode"] == 0)
            status = ("failed" if any(e["returncode"] for e in uploads) else
                      "complete" if completed == event["pending"] else "incomplete")
            lines.append(f"| {event['phase']} | {event['candidates']} | {event['excluded']} | {event['public']} | "
                         f"{event['project']} | {event['pending']} | {event['narBytes'] / 1024 ** 3:.3f} | "
                         f"{duration(sum(e['seconds'] for e in queries))} | "
                         f"{duration(sum(e['seconds'] for e in uploads))} | {status} |")
    query_errors = [event for event in events if event["kind"] == "cache-query" and event["returncode"]]
    if query_errors:
        lines += ["", "Cache queries continued after these errors; details are in `timings.jsonl`:", ""]
        for event in query_errors:
            lines.append(f"- {event['phase']}: `{event['cache']}` (exit {event['returncode']}).")
    builds = [event for event in events if event["kind"] == "build"]
    if builds:
        lines += ["", "### Nix build groups", "", "Group wall times include dependency work and cache transfers.",
                  "", "| Revision | Group | Result | Wall time |", "| --- | --- | --- | --- |"]
        for event in builds:
            status = "success" if event["returncode"] == 0 else event.get("signal", f"exit {event['returncode']}")
            lines.append(f"| {event['pass']} | {event['phase']} | {status} | {duration(event['seconds'])} |")
    activities = [event for event in events if event["kind"] == "activity"]
    for source, title in (("build", "Longest builds"), ("restore", "Longest cache restores")):
        selected = [event for event in activities if event["source"] == source]
        if selected:
            lines += ["", "### " + title, "",
                      "Activities include dependencies. An ended activity alone does not establish build success.",
                      "", "| Group | Store path | Activity | Elapsed |", "| --- | --- | --- | --- |"]
            for event in sorted(selected, key=lambda item: item["seconds"], reverse=True)[:20]:
                status = "ended" if event["finished"] else "unfinished"
                lines.append(f"| {event['phase']} | `{event['path']}` | {status} | {duration(event['seconds'])} |")
    tests = [event for event in events if event["kind"] == "target" and event.get("vm")]
    if tests:
        sources = {"built": "executed", "local": "local reuse", "substituted": "cache restored", "unknown": "unclassified"}
        lines += ["", "### VM results", "", "Execution time covers the Nix VM builder, including guest startup and teardown.",
                  "Cache reuse does not count as a fresh test execution.", "",
                  "| Revision | Test | Source | Result | Execution | Restore |", "| --- | --- | --- | --- | --- | --- |"]
        for event in tests:
            result = "success" if event["success"] else "incomplete/failed"
            lines.append(f"| {event['pass']} | {event['name']} | {sources[event['source']]} | {result} | "
                         f"{duration(event['buildSeconds'])} | {duration(event['restoreSeconds'])} |")
        policy = json.loads((state / "policy.json").read_text())
        expected = {item["name"] for entries in policy["builds"].values() for item in entries if item.get("vm")}
        for pass_name in dict.fromkeys(event["pass"] for event in tests):
            fresh = {event["name"] for event in tests if event["pass"] == pass_name
                     and event["source"] == "built" and event["success"]}
            seconds = sum(event["seconds"] for event in builds if event["pass"] == pass_name
                          and event["phase"].startswith("vm-"))
            completeness = "all required VM tests freshly executed" if fresh == expected else "includes reuse or incomplete tests"
            lines += ["", f"**{pass_name}:** VM stage wall time {duration(seconds)}; "
                      f"{len(fresh)}/{len(expected)} freshly executed successfully ({completeness})."]
    samples = read_records(state / "resources.jsonl")
    evidence = [event for event in events if event["kind"] == "vm-evidence"]
    if evidence:
        lines += ["", "### VM evidence", "", "Paths below are inside the diagnostics artifact.", "",
                  "| Revision | Group | Test | Evidence |", "| --- | --- | --- | --- |"]
        for event in evidence:
            lines.append(f"| {event['pass']} | {event['phase']} | {event['name']} | `{event['path']}` |")
    for event in events:
        if event["kind"] == "evidence-missing":
            lines += ["", f"VM output unavailable for {event['pass']}/{event['name']}: `{event['output']}`."]
        if event["kind"] == "evidence-error":
            lines += ["", f"Evidence collection failed for {event['phase']}: {event['error']}."]
    lines += ["", "### Runner resources", ""]
    if samples:
        gib = 1024 ** 3
        used = max(sample["memoryTotal"] - sample["memoryAvailable"] for sample in samples)
        lines += [f"- Host memory used peak (sampled): {used / gib:.2f} GiB.",
                  f"- Host swap used peak (sampled): {max(s['swapUsed'] for s in samples) / gib:.2f} GiB.",
                  f"- Minimum disk available (sampled): {min(s['diskFree'] for s in samples) / gib:.2f} GiB."]
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
    else:
        lines.append("Resource samples are unavailable; SIGKILL alone does not establish OOM.")
    for filename in ("oom-kernel.log", "oom-userspace.log", "monitor.log"):
        path = state / filename
        if path.exists() and path.read_text().strip() not in ("", "-- No entries --"):
            lines += ["", f"{filename}:", "```text", *path.read_text().splitlines()[-40:], "```"]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("monitor", "sample", "summary"):
        subparser = subparsers.add_parser(operation)
        subparser.add_argument("--state", type=Path, required=True)
        if operation in ("monitor", "sample"):
            subparser.add_argument("--container-pid", type=int, required=True)
    run = subparsers.add_parser("run", help="record wall time and exit status of a CI phase")
    run.add_argument("--state", type=Path, required=True)
    run.add_argument("--phase", required=True)
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.operation == "run":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            parser.error("run requires a command after --")
        started, start = utc_now(), time.monotonic()
        result = subprocess.run(command)
        record(args.state, {"kind": "phase", "phase": args.phase, "started": started,
                            "seconds": time.monotonic() - start, "returncode": result.returncode})
        sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
    elif args.operation == "monitor":
        monitor(args.state, args.container_pid)
    elif args.operation == "sample":
        resource_sample(args.state, cgroup_path(args.container_pid))
    else:
        print(render(args.state), end="")


if __name__ == "__main__":
    main()
