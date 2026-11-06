#!/usr/bin/env python3
"""Export only backup ages and counts; never repository URLs or selected paths."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time

from runner import read_record, scope


def status(root, targets, policy, source, now):
    result = {}
    for target, repository_file in targets.items():
        try:
            expected = scope(policy, source, Path(repository_file).read_bytes())
        except (OSError, ValueError, TypeError):
            expected = None
        operations = {}
        directory = root / ("site-backup-" + target)
        for operation, limit in (("backup", 36 * 3600), ("check", 14 * 86400), ("restore", 14 * 86400), ("maintenance", 45 * 86400)):
            recorded = read_record(root / ("site-backup-" + target) / (operation + "-success.json"))
            matches = expected is not None and all(recorded.get(k) == v for k, v in expected.items())
            timestamp = recorded.get("time")
            age = int(now - timestamp) if matches and isinstance(timestamp, (int, float)) and 0 <= timestamp <= now else None
            item = {"ageSeconds": age, "state": "unknown" if age is None else "fresh" if age <= limit else "stale"}
            if operation == "check" and age is not None:
                part, total = recorded.get("checkedPartition"), recorded.get("partitions")
                if type(part) is int and type(total) is int and 1 <= part <= total:
                    item.update(partition=part, partitions=total)
                else:
                    item = {"ageSeconds": None, "state": "unknown"}
            operations["canaryRestore" if operation == "restore" else operation] = item
        deliveries = {}
        for operation in ("backup", "check", "restore-test", "maintenance"):
            recorded = read_record(directory / (operation + "-notification.json"))
            pending = read_record(directory / (operation + "-pending.json"))
            if pending:
                recorded = pending | {"pending": True}
            if recorded:
                deliveries[operation] = recorded
        if deliveries:
            operations["notifications"] = deliveries
        current = read_record(directory / "current.json")
        if current:
            operations["current"] = current
        operations["results"] = {operation: record for operation in ("automatic", "backup", "check", "restore-test", "maintenance")
                                 if (record := read_record(directory / f"{operation}-result.json"))}
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
