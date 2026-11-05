#!/usr/bin/env python3
"""Select, back up and verify explicit paths with Restic.

Paths in the policy are relative to source. Selections and exclusions are root-relative shell
patterns (fnmatchcase: * also matches /), or exact component names per root.
Symlinks are saved as links, never traversed. Selection fails on unreadable
paths, required missing roots and mount boundaries.
"""
import argparse
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile
import time


def relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError("policy paths must be canonical, nonempty relative paths")
    return path


def atomic_json(path, value):
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".state-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_record(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def scope(policy, source, repository):
    repository = repository.strip()
    if not repository:
        raise ValueError("repository must be explicitly configured")
    identity = hashlib.sha256(repository).hexdigest()
    definition = json.dumps({"policy": json.loads(policy.read_text()),
                             "source": os.path.abspath(source), "repository": identity}, sort_keys=True)
    return {"repository": identity, "scope": hashlib.sha256(definition.encode()).hexdigest()}


def select(source, policy):
    source = source.resolve(strict=True)
    device = source.stat().st_dev
    selected = {}
    absent = []
    roots = [relative(rule["path"]) for rule in policy["roots"]]
    for index, root in enumerate(roots):
        if any(root == other or root in other.parents or other in root.parents for other in roots[index + 1:]):
            raise ValueError("backup roots must not overlap")

    def visit(path, root, rule):
        item = path.lstat()
        rel = path.relative_to(root).as_posix()
        names = rule.get("excludeNames", [])
        patterns = rule.get("excludePaths", [])
        included = not rule.get("includePaths") or any(
            fnmatch.fnmatchcase(rel, pattern) for pattern in rule["includePaths"]
        )
        if rel != "." and (path.name in names or any(fnmatch.fnmatchcase(rel, p) for p in patterns)):
            return
        if item.st_dev != device:
            raise ValueError("selected data crosses a filesystem boundary")
        if stat.S_ISDIR(item.st_mode):
            children = sorted(path.iterdir())
            if not children and included:
                selected[path.relative_to(source).as_posix()] = 0
            for child in children:
                visit(child, root, rule)
        elif included and (stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode)):
            selected[path.relative_to(source).as_posix()] = item.st_size if stat.S_ISREG(item.st_mode) else 0
        # Sockets, FIFOs and device nodes are runtime state, not backup content.

    for rule in policy["roots"]:
        name = relative(rule["path"])
        path = source.joinpath(*name.parts)
        # Ancestor symlinks must not lead out of the selected source tree.
        for parent in list(path.parents)[:-1]:
            if parent == source:
                break
            if parent.is_symlink():
                raise ValueError("backup root has a symlink ancestor")
        try:
            path.lstat()
        except FileNotFoundError:
            if rule.get("required", False):
                raise ValueError("required backup root is missing: " + str(name))
            absent.append(str(name))
            continue
        visit(path, path, rule)
    if not selected or not any(selected.values()):
        raise ValueError("refusing an empty backup selection")
    return {"paths": sorted(selected), "bytes": sum(selected.values()), "missingOptional": absent}


def restic(binary, arguments, state, *, cwd=None):
    result = subprocess.run([binary, *arguments], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # Keep diagnostic details local, mode 0600. Never send paths or credentials to notifications.
    log = state / "last-command.log"
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Restic failed (exit {result.returncode}); inspect protected last-command.log")
    return result.stdout


def backup(args, policy, metadata, common):
    plan = select(args.source, policy)
    with tempfile.NamedTemporaryFile(dir=args.state) as files:
        for name in plan["paths"]:
            files.write(os.fsencode(name) + b"\0")
        files.flush()
        # Stable host/tag grouping lets Restic select an existing parent
        # when the exact file list changes.
        raw = restic(args.restic, ["backup", "--json", "--host", policy["host"], *common, "--group-by", "host,tags", "--files-from-raw", files.name], args.state, cwd=args.source)
    summaries = [json.loads(line) for line in raw.splitlines() if line]
    summary = next(item for item in summaries if item.get("message_type") == "summary")
    atomic_json(args.state / "backup-success.json", metadata | {"time": int(time.time()), "snapshot": summary["snapshot_id"], "files": len(plan["paths"]), "bytes": plan["bytes"], "missingOptional": plan["missingOptional"]})
    print(json.dumps({"operation": "backup", "files": len(plan["paths"]), "bytes": plan["bytes"], "missingOptionalCount": len(plan["missingOptional"])}))


def execute(args):
    policy = json.loads(args.policy.read_text())
    if args.operation == "plan":
        print(json.dumps(select(args.source, policy), ensure_ascii=True, indent=2))
        return
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = os.open(args.state / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "w") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        tag = "site:" + policy["host"]
        common = ["--tag", tag]
        repository = Path(os.environ["RESTIC_REPOSITORY_FILE"]).read_bytes() if os.environ.get("RESTIC_REPOSITORY_FILE") else os.environ.get("RESTIC_REPOSITORY", "").encode()
        metadata = scope(args.policy, args.source, repository) | {"host": policy["host"]}
        success = args.state / (("restore" if args.operation == "restore-test" else args.operation) + "-success.json")
        interval = policy.get("minimumIntervalSeconds", {}).get(args.operation, 0)
        previous = read_record(success)
        if not args.force and previous.get("scope") == metadata["scope"] and isinstance(previous.get("time"), (int, float)) and 0 <= time.time() - previous["time"] < interval:
            print(json.dumps({"operation": args.operation, "skipped": "recent successful run"}))
            return "skipped"
        if args.operation == "backup":
            backup(args, policy, metadata, common)
        elif args.operation == "check":
            progress = args.state / "check-success.json"
            parts = policy.get("checkPartitions", 12)
            if not isinstance(parts, int) or not 1 <= parts <= 100:
                raise ValueError("checkPartitions must be between 1 and 100")
            old = read_record(progress)
            part = old.get("nextPartition", 1) if old.get("partitions") == parts and old.get("scope") == metadata["scope"] else 1
            restic(args.restic, ["check", "--no-cache", f"--read-data-subset={part}/{parts}"], args.state)
            atomic_json(progress, metadata | {"time": int(time.time()), "partitions": parts, "checkedPartition": part, "nextPartition": part % parts + 1})
            print(json.dumps({"operation": "check", "partition": part, "partitions": parts}))
        elif args.operation == "restore-test":
            canary = policy["canary"]
            name = relative(canary["path"])
            with tempfile.TemporaryDirectory(dir=args.state, prefix="restore-") as target:
                restic(args.restic, ["restore", "latest", *common, "--host", policy["host"], "--target", target, "--include", "/" + str(name), "--verify"], args.state)
                restored = Path(target).joinpath(*name.parts)
                if restored.is_symlink() or hashlib.sha256(restored.read_bytes()).hexdigest() != canary["sha256"]:
                    raise RuntimeError("restored canary does not match expected contents")
            atomic_json(args.state / "restore-success.json", metadata | {"time": int(time.time())})
            print(json.dumps({"operation": "restore-test", "canaryRestored": True}))
        elif args.operation in ("retention-plan", "maintenance"):
            if args.operation == "maintenance":
                # Complete a fresh backup and repository structure check while
                # holding the same per-repository lock as every other operation.
                backup(args, policy, metadata, common)
                restic(args.restic, ["check", "--no-cache"], args.state)
            restic(args.restic, ["forget", *( ["--prune"] if args.operation == "maintenance" else ["--dry-run"] ),
                                *common, "--host", policy["host"], "--group-by", "host,tags", *policy["retention"]], args.state)
            if args.operation == "maintenance":
                atomic_json(success, metadata | {"time": int(time.time())})
                print(json.dumps({"operation": "maintenance", "completed": True}))
            else:
                print("Retention dry-run saved to protected last-command.log; no snapshots or packs removed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "backup", "check", "restore-test", "retention-plan", "maintenance"])
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--restic", default="restic")
    parser.add_argument("--force", action="store_true", help="ignore only the minimum interval, never repository locks")
    parser.add_argument("--run-state", type=Path, help="systemd runtime marker for completed or skipped work")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.run_state:
            atomic_json(args.run_state, {"result": "started"})
        outcome = execute(args)
        if args.run_state:
            atomic_json(args.run_state, {"result": outcome or "success"})
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
        print("Backup operation failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
