#!/usr/bin/env python3
"""Record interrupted jobs locally and deliver each operation's latest result."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

from runner import OPERATIONS, atomic_json, read_record, record_result, safe_error


def finalize(state, run_state):
    record = read_record(run_state)
    if record.get("result") not in ("starting", "running"):
        return
    operation = record.get("operation")
    if operation not in OPERATIONS:
        return
    interrupted = os.environ.get("SERVICE_RESULT") in ("signal", "timeout")
    record.update(id=record.get("id", uuid.uuid4().hex), finished=int(time.time()),
                  result="interrupted" if interrupted else "failure")
    record_result(state, record)
    current = read_record(state / "current.json")
    if current.get("id") == record["id"]:
        atomic_json(state / "current.json", record)
    atomic_json(run_state, record)


def deliver(state, host, target, channels, client):
    for operation in OPERATIONS:
        pending = state / f"{operation}-pending.json"
        event = read_record(pending)
        if not event:
            continue
        for channel in channels:
            if channel in event.get("deliveredChannels", []):
                continue
            result = event["result"]
            body = f"host={host}; target={target}; operation={operation}; result={result}"
            if result in ("failure", "interrupted"):
                if event.get("phase"):
                    body += "; phase=" + event["phase"]
                if "resticExitCode" in event:
                    body += "; resticExitCode=" + str(event["resticExitCode"])
                if event.get("error"):
                    body += "; error=" + safe_error(event["error"])
            command = [client, "send", "--group", "backup", "--channel", channel,
                       "--title", f"{host}: {operation} {result}",
                       body]
            try:
                completed = subprocess.run(command, capture_output=True, timeout=100)
                delivery = json.loads(completed.stdout)["channels"][0]
            except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
                delivery = {"channel": channel, "delivered": False}
            print(json.dumps({"target": target, "operation": operation, "id": event["id"],
                              "result": result, "delivery": delivery}), flush=True)
            with (state / "notifications.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                current = read_record(pending)
                if current.get("id") != event["id"]:
                    break
                if delivery.get("delivered"):
                    current["deliveredChannels"].append(channel)
                current.setdefault("channels", {})[channel] = delivery
                current["lastAttempt"] = int(time.time())
                atomic_json(state / f"{operation}-notification.json", current)
                if all(name in current["deliveredChannels"] for name in channels):
                    pending.unlink()
                else:
                    atomic_json(pending, current)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    finish = sub.add_parser("finalize")
    finish.add_argument("--state", type=Path, required=True)
    finish.add_argument("--run-state", type=Path, required=True)
    send = sub.add_parser("deliver")
    send.add_argument("--state", type=Path, required=True)
    send.add_argument("--host", required=True)
    send.add_argument("--target", required=True)
    send.add_argument("--client", required=True)
    send.add_argument("--channel", action="append", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "finalize":
        finalize(args.state, args.run_state)
    else:
        deliver(args.state, args.host, args.target, list(dict.fromkeys(args.channel)), args.client)


if __name__ == "__main__":
    main()
