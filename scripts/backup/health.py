#!/usr/bin/env python3
"""Describe current backup health without repository URLs or selected paths."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time

from runner import OPERATIONS, atomic_json, attempt, automatic_decision, read_record, scope


def status(root, targets, policy, source, now):
    result = {}
    for target, settings in targets.items():
        repository_file = settings["repositoryFile"] if isinstance(settings, dict) else settings
        policy_file = Path(settings["policyFile"]) if isinstance(settings, dict) else policy
        definition = {}
        try:
            definition = json.loads(policy_file.read_text())
            expected = scope(policy_file, source, Path(repository_file).read_bytes())
        except (OSError, ValueError, TypeError):
            expected = None
        operations = {}
        directory = root / ("site-backup-" + target)
        def matches(record):
            return expected is not None and all(record.get(k) == v for k, v in expected.items())
        observation_path = directory / "health-scope.json"
        observed = read_record(observation_path)
        if expected is not None and (not observation_path.exists() or (observed and not matches(observed))):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            observed = expected | {"time": int(now)}
            atomic_json(observation_path, observed)
        results = {operation: record for operation in ("automatic", "backup", "check", "restore-test", "maintenance")
                   if (record := read_record(directory / f"{operation}-result.json"))
                   and (matches(record) or (operation == "automatic" and record.get("result") == "skipped"))}
        for operation, limit in (("backup", 36 * 3600), ("check", 14 * 86400), ("restore", 14 * 86400), ("maintenance", 45 * 86400)):
            name = "restore-test" if operation == "restore" else operation
            limit = definition.get("health", {}).get(name, limit)
            success_path = directory / (operation + "-success.json")
            recorded = read_record(success_path)
            timestamp = recorded.get("time")
            age = int(now - timestamp) if matches(recorded) and isinstance(timestamp, (int, float)) and 0 <= timestamp <= now else None
            item = {"ageSeconds": age, "state": "unknown" if age is None else "fresh" if age <= limit else "stale"}
            if matches(observed) and (not success_path.exists() or (recorded and not matches(recorded))):
                deadline = observed["time"] + limit
                item.update(state="pending" if now <= deadline else "stale", dueAt=deadline)
            if operation == "check" and age is not None:
                part, total = recorded.get("checkedPartition"), recorded.get("partitions")
                if type(part) is int and type(total) is int and 1 <= part <= total:
                    item.update(partition=part, partitions=total)
                else:
                    item = {"ageSeconds": None, "state": "unknown"}
            last = attempt(directory, name, expected) if expected else {}
            last = last or results.get(name, {})
            if last.get("result") == "failure" and (age is None or last.get("finished", 0) >= timestamp):
                item["state"] = "failed"
            operations["canaryRestore" if operation == "restore" else operation] = item
        if expected and definition.get("schedule"):
            operations["automatic"] = {
                operation: automatic_decision(directory, operation, expected, definition, now,
                                              definition["schedule"].get("offsetMinutes", 0))
                | ({"requires": ["AC power", "successful backup in this window"]} if operation != "backup" else {})
                for operation in OPERATIONS
            }
            operations["attempts"] = {op: record for op in OPERATIONS
                                      if (record := attempt(directory, op, expected))}
        deliveries = {}
        for operation in ("backup", "check", "restore-test", "maintenance"):
            recorded = read_record(directory / (operation + "-notification.json"))
            pending = read_record(directory / (operation + "-pending.json"))
            if pending:
                recorded = pending | {"pending": True}
            if recorded:
                deliveries[operation] = recorded | {"currentScope": matches(recorded)}
        if deliveries:
            operations["notifications"] = deliveries
        current = read_record(directory / "current.json")
        if matches(current):
            if current.get("result") == "running" and current.get("bootId") != Path("/proc/sys/kernel/random/boot_id").read_text().strip():
                current = current | {"result": "interrupted"}
            operations["current"] = current
        operations["results"] = results
        result[target] = operations
    return {"generated": int(now), "repositories": result,
            "fresh": sum(v["backup"]["state"] == "fresh" for v in result.values()), "total": len(result)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, default=Path("/var/lib"))
    parser.add_argument("--targets", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    body = status(args.state_root, json.loads(args.targets.read_text()), args.policy, args.source, time.time())
    fd, temporary = tempfile.mkstemp(dir=args.output.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(body, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, args.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
