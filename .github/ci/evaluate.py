#!/usr/bin/env python3
"""Evaluate independent CI jobs and write their build and publication inventory."""

import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

from report import record, utc_now


ROOT = Path(__file__).resolve().parents[2]


def progress(state, started, completed, total):
    event = {"kind": "evaluation-progress", "time": utc_now(),
             "seconds": time.monotonic() - started, "completed": completed, "total": total}
    samples = state / "resources.jsonl"
    if samples.exists():
        # The runner monitor owns resource sampling; its latest complete line
        # also survives here in the Actions console if the runner disappears.
        lines = samples.read_bytes().split(b"\n")[:-1]
        if lines:
            event["resources"] = json.loads(lines[-1])
    else:
        memory = {line.split()[0].rstrip(":"): int(line.split()[1]) * 1024
                  for line in Path("/proc/meminfo").read_text().splitlines() if len(line.split()) == 3}
        event["memoryAvailable"] = memory["MemAvailable"]
    print(json.dumps(event), flush=True)


def evaluate_jobs(command, expected, state):
    """A zero process exit status can still contain failed evaluation records."""
    results, failures = {}, []
    started = time.monotonic()
    next_progress = started + 60
    state.mkdir(parents=True, exist_ok=True)
    with (state / "evaluation.jsonl").open("wb") as evidence, selectors.DefaultSelector() as selector:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, start_new_session=True, cwd=ROOT)
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""

        def consume(line):
            evidence.write(line + b"\n")
            evidence.flush()
            item = json.loads(line)
            name = item.get("attr")
            error = item.get("error")
            if error or not item.get("drvPath") or not item.get("outputs") or not all(item["outputs"].values()):
                failures.append(name or "unknown attribute")
            elif name not in expected or name in results:
                raise RuntimeError(f"Unexpected or duplicate evaluation result: {name}")
            else:
                results[name] = item
            stats = item.get("stats", {})
            record(state, {"kind": "evaluation", "name": name, "success": not error and name in results,
                           "seconds": stats.get("wallMs", 0) / 1000, "stats": stats})
            print(f"Evaluated {name}: {'failed' if name not in results else 'success'} "
                  f"({stats.get('wallMs', 0) / 1000:.1f}s)", flush=True)

        try:
            while selector.get_map():
                for key, _ in selector.select(timeout=max(0, next_progress - time.monotonic())):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    pending += chunk
                    lines = pending.split(b"\n")
                    pending = lines.pop()
                    for line in lines:
                        if line.strip():
                            consume(line)
                if time.monotonic() >= next_progress:
                    progress(state, started, len(results), len(expected))
                    next_progress = time.monotonic() + 60
            if pending.strip():
                consume(pending)
            returncode = process.wait()
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
    missing = expected - results.keys()
    if returncode or failures or missing:
        raise RuntimeError(f"Inventory evaluation failed (exit {returncode}); "
                           f"failed or missing: {', '.join(sorted(missing | set(failures)))}; "
                           "see evaluation.jsonl")
    return results


def evaluate_inventory(state, scope, host):
    state.mkdir(parents=True, exist_ok=True)
    destination = state / "policy.json"
    destination.unlink(missing_ok=True)
    # CLI values are JSON data inside a Nix string, including literal ${...}.
    selection = json.dumps(json.dumps({"scope": scope, "hostName": host}, ensure_ascii=False),
                           ensure_ascii=False).replace("${", r"\${")
    expression = ('(import ./nix/ci.nix ({ '
                  'flake = builtins.getFlake ("git+file://" + toString ./.); '
                  '} // builtins.fromJSON ' + selection + ')).')
    arguments = ["--no-update-lock-file", "--impure"]

    def query(attribute):
        return json.loads(subprocess.check_output(
            ["nix", "eval", "--json", *arguments, "--expr", expression + attribute], cwd=ROOT))

    groups = query("groups")
    expected = {name for names in groups.values() for name in names}
    results = evaluate_jobs(
        ["nix-eval-jobs", "--workers", "2", "--max-memory-size", "5120",
         "--impure", "--expr", expression + "jobs"], expected, state)
    policy = query("policy")
    builds = {"private": policy.pop("privateBuilds")}
    for group, names in groups.items():
        builds[group] = [{"name": name, "drv": results[name]["drvPath"],
                          "outputs": list(results[name]["outputs"].values()),
                          **({"vm": True} if group.startswith("vm-") else {})} for name in names]
    policy.update(scope=scope, builds=builds,
                  roots=sorted({item["drv"] for entries in builds.values() for item in entries}))
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(policy, indent=2) + "\n")
    temporary.replace(destination)
    print(f"Build inventory: {destination} ({len(results)} evaluated jobs)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=["laptop", "remote"], required=True)
    parser.add_argument("--host", help="NixOS host to evaluate for the laptop scope")
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    if args.scope == "laptop" and not args.host:
        parser.error("--host is required for the laptop scope")
    started, start = utc_now(), time.monotonic()
    status = 1
    try:
        evaluate_inventory(args.state, args.scope, args.host)
        status = 0
    finally:
        record(args.state, {"kind": "phase", "phase": "inventory", "started": started,
                            "seconds": time.monotonic() - start, "returncode": status})


if __name__ == "__main__":
    main()
