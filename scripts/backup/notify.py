#!/usr/bin/env python3
"""Record delivery separately from the systemd backup result, without forwarding logs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from runner import atomic_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--operation", required=True, choices=["backup", "check", "restore-test", "maintenance"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--run-state", type=Path, required=True)
    parser.add_argument("--client", required=True)
    parser.add_argument("--channel", action="append", required=True)
    args = parser.parse_args()
    try:
        marker = json.loads(args.run_state.read_text())
    except (OSError, ValueError):
        marker = {}
    if marker.get("result") == "skipped":
        return
    result = "success" if os.environ.get("SERVICE_RESULT") == "success" and marker.get("result") == "success" else "failure"
    command = [args.client, "send", "--group", "backup",
               "--title", f"{args.host}: {args.operation} {result}"]
    for channel in args.channel:
        command.extend(["--channel", channel])
    command.append(f"host={args.host}; target={args.target}; operation={args.operation}; result={result}")
    try:
        completed = subprocess.run(command, capture_output=True, timeout=100 * len(args.channel) + 5)
        delivery = json.loads(completed.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        delivery = {"channels": [{"channel": name, "delivered": False} for name in args.channel]}
    record = {"time": int(time.time()), "operationResult": result, **delivery}
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    atomic_json(args.state / f"{args.operation}-notification.json", record)
    print(json.dumps({"target": args.target, "operation": args.operation, "notification": record}))


if __name__ == "__main__":
    # systemd must retain the original backup result even if recording delivery fails.
    try:
        main()
    except (OSError, ValueError, KeyError):
        print('{"notification":{"delivered":false,"error":"local-state"}}')
