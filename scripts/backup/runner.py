#!/usr/bin/env python3
"""Select, back up and verify explicit paths with Restic.

Paths in the policy are relative to source. Selections and exclusions are root-relative shell
patterns (fnmatchcase: * also matches /), or exact component names per root.
Symlinks are saved as links, never traversed. Selection fails on unreadable
paths, required missing roots and mount boundaries.
"""
import argparse
from datetime import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from zoneinfo import ZoneInfo


OPERATIONS = ("backup", "check", "restore-test", "maintenance")


class Interrupted(Exception):
    pass


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
    data = {k: v for k, v in json.loads(policy.read_text()).items()
            if k not in ("schedule", "minimumIntervalSeconds")}
    definition = json.dumps({"policy": data,
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
    """Stream bounded diagnostics to disk; retain only the backup summary in memory."""
    log = state / "last-command.log"
    summary = None
    process = subprocess.Popen([binary, *arguments], cwd=cwd,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        with process.stdout:
            stream = log.open("wb")
            try:
                log.chmod(0o600)
                for line in process.stdout:
                    if stream.tell() + len(line) > 4 * 1024 * 1024:
                        stream.close()
                        log.replace(state / "last-command.log.1")
                        stream = log.open("wb")
                        log.chmod(0o600)
                    stream.write(line)
                    stream.flush()
                    if arguments[0] == "backup":
                        try:
                            item = json.loads(line)
                            if item.get("message_type") == "summary":
                                summary = item
                        except (ValueError, AttributeError):
                            pass
                code = process.wait()
            finally:
                stream.close()
        if code:
            raise RuntimeError(f"Restic failed (exit {code}); inspect protected last-command.log")
        return summary
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def backup(args, policy, metadata, common):
    plan = select(args.source, policy)
    with tempfile.NamedTemporaryFile(dir=args.state) as files:
        for name in plan["paths"]:
            files.write(os.fsencode(name) + b"\0")
        files.flush()
        # Stable host/tag grouping lets Restic select an existing parent
        # when the exact file list changes.
        summary = restic(args.restic, ["backup", "--json", "--host", policy["host"], *common, "--group-by", "host,tags", "--files-from-raw", files.name], args.state, cwd=args.source)
    if summary is None:
        raise RuntimeError("Restic completed without a backup summary")
    atomic_json(args.state / "backup-success.json", metadata | {"time": int(time.time()), "snapshot": summary["snapshot_id"], "files": len(plan["paths"]), "bytes": plan["bytes"], "missingOptional": plan["missingOptional"]})
    print(json.dumps({"operation": "backup", "files": len(plan["paths"]), "bytes": plan["bytes"], "missingOptionalCount": len(plan["missingOptional"])}))


def window_at(schedule, now, offset=0):
    local = datetime.fromtimestamp(now, ZoneInfo(schedule["timeZone"]))
    minute = local.hour * 60 + local.minute
    for window in schedule["windows"]:
        start, end = (sum(int(v) * factor for v, factor in zip(window[key].split(":"), (60, 1)))
                      for key in ("start", "end"))
        if start + offset <= minute < end:
            return window | {"id": f"{local.date()}:{window['start']}:{window['end']}"}
    return None


def on_ac_power():
    # systemd-ac-power also handles desktops with no battery or power supplies.
    return subprocess.run(["systemd-ac-power"], timeout=5, check=False).returncode == 0


def success_path(state, operation):
    return state / (("restore" if operation == "restore-test" else operation) + "-success.json")


def recent(state, operation, metadata, policy, now):
    previous = read_record(success_path(state, operation))
    interval = policy.get("minimumIntervalSeconds", {}).get(operation, 0)
    return (previous.get("scope") == metadata["scope"]
            and isinstance(previous.get("time"), (int, float))
            and 0 <= now - previous["time"] < interval)


def record_result(state, record):
    operation = record["operation"]
    atomic_json(state / f"{operation}-result.json", record)
    if record["result"] == "skipped":
        return
    # Delivery acknowledges only the same event it read. The lock is held for
    # local updates, never across a network request or a Restic operation.
    with (state / "notifications.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        atomic_json(state / f"{operation}-pending.json", record | {"deliveredChannels": []})


def run_operation(args, policy, metadata, operation, *, checked=False, reuse_backup=False):
    record = metadata | {"id": uuid.uuid4().hex, "operation": operation,
              "bootId": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
              "result": "running", "started": int(time.time()), "phase": operation}

    def phase(name):
        record["phase"] = name
        atomic_json(args.state / "current.json", record)
        if args.run_state:
            atomic_json(args.run_state, record)

    phase(operation)
    common = ["--tag", "site:" + policy["host"]]
    try:
        if operation == "backup":
            phase("selection-and-backup")
            backup(args, policy, metadata, common)
        elif operation == "check":
            parts = policy.get("checkPartitions", 12)
            old = read_record(success_path(args.state, operation))
            part = old.get("nextPartition", 1) if old.get("partitions") == parts and old.get("scope") == metadata["scope"] else 1
            restic(args.restic, ["check", "--no-cache", f"--read-data-subset={part}/{parts}"], args.state)
            atomic_json(success_path(args.state, operation), metadata | {
                "time": int(time.time()), "partitions": parts, "checkedPartition": part,
                "nextPartition": part % parts + 1})
        elif operation == "restore-test":
            canary = policy["canary"]
            name = relative(canary["path"])
            with tempfile.TemporaryDirectory(dir=args.state, prefix="restore-") as target:
                restic(args.restic, ["restore", "latest", *common, "--host", policy["host"],
                                    "--target", target, "--include", "/" + str(name), "--verify"], args.state)
                restored = Path(target).joinpath(*name.parts)
                if restored.is_symlink() or hashlib.sha256(restored.read_bytes()).hexdigest() != canary["sha256"]:
                    raise RuntimeError("restored canary does not match expected contents")
            atomic_json(success_path(args.state, operation), metadata | {"time": int(time.time())})
        elif operation in ("retention-plan", "maintenance"):
            if operation == "maintenance":
                if not reuse_backup:
                    phase("selection-and-backup")
                    backup(args, policy, metadata, common)
                if not checked:
                    phase("check-before-prune")
                    restic(args.restic, ["check", "--no-cache"], args.state)
                if reuse_backup:
                    window = window_at(policy["schedule"], time.time(), args.offset_minutes)
                    if not window or window["id"] != metadata["window"] or not window["maintenance"] or not on_ac_power():
                        record.update(result="skipped", reason="awaiting maintenance window and AC power")
                        return
                phase("forget-and-prune")
            restic(args.restic, ["forget", *( ["--prune"] if operation == "maintenance" else ["--dry-run"] ),
                                *common, "--host", policy["host"], "--group-by", "host,tags", *policy["retention"]], args.state)
            if operation == "maintenance":
                phase("check-after-prune")
                restic(args.restic, ["check", "--no-cache"], args.state)
                atomic_json(success_path(args.state, operation), metadata | {"time": int(time.time())})
        record["result"] = "success"
    except (Interrupted, KeyboardInterrupt):
        record["result"] = "interrupted"
        raise
    except Exception:
        record["result"] = "failure"
        raise
    finally:
        record["finished"] = int(time.time())
        if operation in OPERATIONS:
            record_result(args.state, record)
        atomic_json(args.state / "current.json", record)
        if args.run_state:
            atomic_json(args.run_state, record)
        print(json.dumps(record), flush=True)


def execute(args):
    policy = json.loads(args.policy.read_text())
    if args.operation == "plan":
        print(json.dumps(select(args.source, policy), ensure_ascii=True, indent=2))
        return
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = os.open(args.state / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "w") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "repository busy"
        repository = Path(os.environ["RESTIC_REPOSITORY_FILE"]).read_bytes() if os.environ.get("RESTIC_REPOSITORY_FILE") else os.environ.get("RESTIC_REPOSITORY", "").encode()
        metadata = scope(args.policy, args.source, repository) | {"host": policy["host"]}
        schedule = policy.get("schedule")
        window = window_at(schedule, time.time(), args.offset_minutes) if schedule else None
        if window:
            metadata["window"] = window["id"]
        if args.operation != "automatic":
            if not args.force and recent(args.state, args.operation, metadata, policy, time.time()):
                return "recent successful run"
            run_operation(args, policy, metadata, args.operation)
            return
        if window is None:
            return "outside backup window"
        previous = read_record(success_path(args.state, "backup"))
        completed = False
        if previous.get("scope") != metadata["scope"] or previous.get("window") != window["id"]:
            run_operation(args, policy, metadata, "backup")
            completed = True
        checked = False
        for operation in ("check", "restore-test", "maintenance"):
            current = window_at(schedule, time.time(), args.offset_minutes)
            if not current or current["id"] != window["id"] or not current["maintenance"] or not on_ac_power():
                break
            if not args.force and recent(args.state, operation, metadata, policy, time.time()):
                continue
            run_operation(args, policy, metadata, operation, checked=checked, reuse_backup=True)
            completed = True
            checked = checked or operation == "check"
        if not completed:
            return "window work already completed or awaiting maintenance conditions"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "automatic", *OPERATIONS, "retention-plan"])
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--restic", default="restic")
    parser.add_argument("--force", action="store_true", help="ignore only the minimum interval, never repository locks")
    parser.add_argument("--offset-minutes", type=int, default=0)
    parser.add_argument("--run-state", type=Path, help="systemd runtime marker for completed or skipped work")
    args = parser.parse_args()
    os.umask(0o077)
    def interrupted(_signum, _frame):
        raise Interrupted()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if args.run_state:
            atomic_json(args.run_state, {"result": "starting", "operation": args.operation})
        outcome = execute(args)
        if outcome:
            record = {"operation": args.operation, "result": "skipped", "reason": outcome,
                      "finished": int(time.time())}
            if args.run_state:
                atomic_json(args.run_state, record)
            record_result(args.state, record)
            print(json.dumps(record))
    except (Interrupted, KeyboardInterrupt):
        print("Backup operation interrupted", file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, StopIteration, RuntimeError, subprocess.SubprocessError) as error:
        print("Backup operation failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
