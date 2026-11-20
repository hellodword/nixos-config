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
import re
import selectors
import socket
import stat
import signal
import subprocess
import sys
import tempfile
import time
import uuid


from state import OPERATIONS, atomic_json, read_record, success_path, attempt, record_result, safe_error
from schedule import automatic_decision, window_at, recent
STOP_AT = None


class Interrupted(Exception):
    def __init__(self, code=None):
        self.code = code


class ResticError(RuntimeError):
    def __init__(self, code, detail, summary=None, errors=()):
        self.code = code
        self.detail = safe_error(detail)
        self.summary = summary
        self.errors = tuple(errors)
        super().__init__(f"Restic failed (exit {code}): {self.detail}")


def check_interrupted():
    if STOP_AT is not None:
        raise Interrupted()


def relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError("policy paths must be canonical, nonempty relative paths")
    return path


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
        check_interrupted()
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
                raise ValueError("required backup root is missing: " + str(path))
            absent.append(str(name))
            continue
        visit(path, path, rule)
    if not selected or not any(selected.values()):
        raise ValueError("refusing an empty backup selection")
    return {"paths": sorted(selected), "bytes": sum(selected.values()), "missingOptional": absent}


def restic_command(binary, arguments, state, *, cwd=None, capture=False, log_name="last-command.log"):
    """Drain output through cancellation so Restic can release its remote lock."""
    check_interrupted()
    log = state / log_name
    summary = None
    item_errors = []
    tail = b""
    captured = bytearray()
    pending = b""
    error = None
    deadline = None
    process = subprocess.Popen([binary, *arguments], cwd=cwd,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        with selectors.DefaultSelector() as poll:
            poll.register(process.stdout, selectors.EVENT_READ)
            stream = log.open("wb")
            try:
                log.chmod(0o600)
                while poll.get_map() or process.poll() is None:
                    if STOP_AT is not None and deadline is None:
                        deadline = STOP_AT + 25
                        if process.poll() is None:
                            process.terminate()
                    if deadline is not None and time.monotonic() >= deadline and process.poll() is None:
                        process.kill()
                    events = poll.select(timeout=0.1)
                    if not events:
                        continue
                    block = os.read(process.stdout.fileno(), 65536)
                    if not block:
                        poll.unregister(process.stdout)
                        continue
                    if stream.tell() + len(block) > 4 * 1024 * 1024:
                        stream.close()
                        log.replace(state / (log_name + ".1"))
                        stream = log.open("wb")
                        log.chmod(0o600)
                    stream.write(block)
                    stream.flush()
                    tail = (tail + block)[-8192:]
                    if capture:
                        captured.extend(block)
                        if len(captured) > 1024 * 1024:
                            raise RuntimeError("lock inspection output exceeds limit")
                    pending += block
                    lines = pending.split(b"\n")
                    pending = lines.pop()[-65536:]
                    for line in lines:
                        try:
                            item = json.loads(line)
                            if item.get("message_type") == "summary":
                                summary = item
                            elif item.get("message_type") == "error":
                                detail = item.get("error")
                                item_errors.append(detail.get("message", "") if isinstance(detail, dict) else str(detail or ""))
                            elif item.get("message_type") == "exit_error":
                                error = item.get("message", "")
                        except (ValueError, AttributeError):
                            pass
                if pending:
                    try:
                        item = json.loads(pending)
                        if item.get("message_type") == "summary":
                            summary = item
                        elif item.get("message_type") == "error":
                            detail = item.get("error")
                            item_errors.append(detail.get("message", "") if isinstance(detail, dict) else str(detail or ""))
                        elif item.get("message_type") == "exit_error":
                            error = item.get("message", "")
                    except (ValueError, AttributeError):
                        pass
                code = process.wait()
            finally:
                stream.close()
        if STOP_AT is not None:
            raise Interrupted(code)
        if code:
            raise ResticError(code, error or tail.decode(errors="replace"), summary=summary, errors=item_errors)
        return bytes(captured) if capture else summary
    finally:
        # Unexpected local I/O failures still leave the pipe open during cleanup.
        if process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=25)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        process.stdout.close()


def boot_time():
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            if line.startswith("btime "):
                return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def process_comm(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except FileNotFoundError:
        return None
    except OSError:
        return ""


def lock_created_before_boot(lock, btime):
    raw_time = lock.get("time")
    if not isinstance(raw_time, str) or btime is None:
        return False
    normalized = re.sub(r"\.(\d{6})\d+", r".\1", raw_time)
    try:
        created = datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return False
    return created < btime


def recover_locks(binary, state):
    """Only an explicitly single-host repository may remove proven dead local locks."""
    def inspect(arguments):
        return restic_command(binary, ["--no-lock", "--quiet", *arguments], state,
                              capture=True, log_name="lock-recovery.log")

    ids = inspect(["list", "locks"]).decode().splitlines()
    if any(not re.fullmatch(r"[0-9a-f]{64}", identity) for identity in ids):
        raise RuntimeError("cannot inspect repository locks")
    hostname = socket.gethostname()
    btime = boot_time()
    for identity in ids:
        lock = json.loads(inspect(["cat", "lock", identity]))
        pid = lock.get("pid")
        if lock.get("hostname") != hostname or type(pid) is not int or pid <= 0:
            raise RuntimeError("repository lock owner cannot be verified locally")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        if lock_created_before_boot(lock, btime):
            continue
        comm = process_comm(pid)
        if comm is None or (comm and comm not in ("restic", ".restic-wrapped")):
            continue
        raise RuntimeError("repository lock may belong to a live process")
    # Never --remove-all. The local flock remains held through inspection,
    # ordinary Restic stale-lock removal and the single retry.
    restic_command(binary, ["unlock"], state, log_name="lock-recovery.log")


def restic(binary, arguments, state, *, cwd=None, recover_stale_locks=False):
    try:
        return restic_command(binary, arguments, state, cwd=cwd)
    except ResticError as error:
        if error.code != 11 or not recover_stale_locks:
            raise
        try:
            recover_locks(binary, state)
        except Interrupted:
            raise
        except (OSError, ValueError, RuntimeError) as recovery:
            raise ResticError(11, f"{error.detail}; lock recovery: {safe_error(recovery)}") from recovery
    return restic_command(binary, arguments, state, cwd=cwd)


def transient_vanished_only(source, policy, paths, errors):
    if any("no such file or directory" not in message.lower() for message in errors):
        return False
    source = source.resolve(strict=True)
    for rule in policy["roots"]:
        if rule.get("required", False) and not source.joinpath(*relative(rule["path"]).parts).exists():
            return False
    vanished = False
    for rel in paths:
        candidate = source.joinpath(*PurePosixPath(rel).parts)
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            vanished = True
            continue
        except OSError:
            return False
        if stat.S_ISREG(info.st_mode):
            try:
                with candidate.open("rb"):
                    pass
            except FileNotFoundError:
                vanished = True
            except OSError:
                return False
    return vanished or bool(errors)


def backup(args, policy, metadata, common):
    plan = select(args.source, policy)
    partial_warning = False
    with tempfile.NamedTemporaryFile(dir=args.state) as files:
        for name in plan["paths"]:
            files.write(os.fsencode(name) + b"\0")
        files.flush()
        # Stable host/tag grouping lets Restic select an existing parent
        # when the exact file list changes.
        try:
            summary = restic(
                args.restic,
                ["backup", "--json", "--host", policy["host"], *common, "--group-by", "host,tags", "--files-from-raw", files.name],
                args.state,
                cwd=args.source,
                recover_stale_locks=policy.get("recoverStaleLocks", False),
            )
        except ResticError as error:
            if (
                error.code == 3
                and isinstance(error.summary, dict)
                and error.summary.get("snapshot_id")
                and transient_vanished_only(args.source, policy, plan["paths"], error.errors)
            ):
                summary = error.summary
                partial_warning = True
            else:
                raise
    if not isinstance(summary, dict) or not summary.get("snapshot_id"):
        raise RuntimeError("Restic completed without a backup summary")
    success_record = metadata | {
        "time": int(time.time()),
        "snapshot": summary["snapshot_id"],
        "files": len(plan["paths"]),
        "bytes": plan["bytes"],
        "missingOptional": plan["missingOptional"],
    }
    if partial_warning:
        success_record["partialReadWarning"] = True
    atomic_json(args.state / "backup-success.json", success_record)
    summary_event = {
        "operation": "backup",
        "files": len(plan["paths"]),
        "bytes": plan["bytes"],
        "missingOptionalCount": len(plan["missingOptional"]),
    }
    if partial_warning:
        summary_event["partialReadWarning"] = True
    print(json.dumps(summary_event))
    return partial_warning


def on_ac_power():
    # systemd-ac-power also handles desktops with no battery or power supplies.
    return subprocess.run(["systemd-ac-power"], timeout=5, check=False).returncode == 0


def run_operation(args, policy, metadata, operation, *, reuse_backup=False):
    check_interrupted()
    record = metadata | {"id": uuid.uuid4().hex, "operation": operation,
              "bootId": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
              "result": "running", "started": int(time.time()), "phase": operation}

    def phase(name):
        check_interrupted()
        record["phase"] = name
        atomic_json(args.state / "current.json", record)
        if args.run_state:
            atomic_json(args.run_state, record)

    phase(operation)
    if operation in OPERATIONS:
        atomic_json(args.state / f"{operation}-attempt.json", record)
    if operation == "backup" and "window" in metadata:
        counted = read_record(args.state / "backup-window.json")
        count = counted.get("count", 0) if counted.get("window") == metadata["window"] else 0
        atomic_json(args.state / "backup-window.json", metadata | {"count": count + 1})

    def command(arguments):
        return restic(args.restic, arguments, args.state,
                      recover_stale_locks=policy.get("recoverStaleLocks", False))

    common = ["--tag", "site:" + policy["host"]]
    check_flags = ["--with-cache"] if policy.get("checkWithCache", False) else []
    try:
        if operation == "backup":
            phase("selection-and-backup")
            if backup(args, policy, metadata, common):
                record["partialReadWarning"] = True
        elif operation == "check":
            parts = policy.get("checkPartitions", 12)
            old = read_record(success_path(args.state, operation))
            part = old.get("nextPartition", 1) if old.get("partitions") == parts else 1
            command(["check", *check_flags, f"--read-data-subset={part}/{parts}"])
            atomic_json(success_path(args.state, operation), metadata | {
                "time": int(time.time()), "partitions": parts, "checkedPartition": part,
                "nextPartition": part % parts + 1})
        elif operation == "restore-test":
            canary = policy["canary"]
            name = relative(canary["path"])
            with tempfile.TemporaryDirectory(dir=args.state, prefix="restore-") as target:
                command(["restore", "latest", *common, "--host", policy["host"],
                         "--target", target, "--include", "/" + str(name), "--verify"])
                restored = Path(target).joinpath(*name.parts)
                if restored.is_symlink() or hashlib.sha256(restored.read_bytes()).hexdigest() != canary["sha256"]:
                    raise RuntimeError("restored canary does not match expected contents")
            atomic_json(success_path(args.state, operation), metadata | {"time": int(time.time())})
        elif operation in ("retention-plan", "maintenance"):
            if operation == "maintenance":
                if not reuse_backup:
                    phase("selection-and-backup")
                    if backup(args, policy, metadata, common):
                        record["partialReadWarning"] = True
                if reuse_backup:
                    offset = policy.get("schedule", {}).get("offsetMinutes", 0)
                    window = window_at(policy["schedule"], time.time(), offset)
                    if not window or window["id"] != metadata["window"] or not window["maintenance"] or not on_ac_power():
                        record.update(result="skipped", reason="awaiting maintenance window and AC power")
                        return
                phase("forget-and-prune")
            command(["forget", *( ["--prune"] if operation == "maintenance" else ["--dry-run"] ),
                     *common, "--host", policy["host"], "--group-by", "host,tags", *policy["retention"]])
            if operation == "maintenance":
                phase("check-after-prune")
                command(["check", *check_flags])
                atomic_json(success_path(args.state, operation), metadata | {"time": int(time.time())})
        record["result"] = "success"
    except (Interrupted, KeyboardInterrupt) as error:
        record["result"] = "interrupted"
        if getattr(error, "code", None) is not None:
            record["resticExitCode"] = error.code
        raise
    except Exception as error:
        record["result"] = "failure"
        record["error"] = safe_error(error)
        if isinstance(error, ResticError):
            record["resticExitCode"] = error.code
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
    check_interrupted()
    policy = json.loads(args.policy.read_text())
    offset = policy.get("schedule", {}).get("offsetMinutes", 0)
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
        metadata = {"host": policy["host"]}
        schedule = policy.get("schedule")
        window = window_at(schedule, time.time(), offset) if schedule else None
        if window:
            metadata["window"] = window["id"]
        if args.operation != "automatic":
            if not args.force and recent(args.state, args.operation, policy, time.time()):
                return "recent successful run"
            run_operation(args, policy, metadata, args.operation)
            return
        if not policy.get("automatic", {}).get("enable", True):
            return "automatic execution disabled"
        if window is None:
            return "outside backup window"
        previous = read_record(success_path(args.state, "backup"))
        completed = False
        if previous.get("window") != window["id"]:
            decision = automatic_decision(args.state, "backup", policy, time.time(), offset)
            if decision["nextEligibleAt"] is None or decision["nextEligibleAt"] > time.time():
                return decision["reason"]
            run_operation(args, policy, metadata, "backup")
            completed = True
        order = sorted(OPERATIONS[1:], key=lambda op: attempt(args.state, op).get("started", 0))
        for operation in order:
            check_interrupted()
            current = window_at(schedule, time.time(), offset)
            if not current or current["id"] != window["id"] or not current["maintenance"] or not on_ac_power():
                break
            decision = automatic_decision(args.state, operation, policy, time.time(), offset)
            if decision["nextEligibleAt"] is None or decision["nextEligibleAt"] > time.time():
                continue
            run_operation(args, policy, metadata, operation, reuse_backup=True)
            completed = True
        if not completed:
            return "window work already completed or awaiting maintenance conditions"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "automatic", *OPERATIONS, "retention-plan"])
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--restic", default="restic")
    parser.add_argument("--force", action="store_true", help="ignore the manual operation's minimum interval; automatic policy and locks still apply")
    parser.add_argument("--run-state", type=Path, help="systemd runtime marker for completed or skipped work")
    args = parser.parse_args()
    os.umask(0o077)
    def interrupted(_signum, _frame):
        global STOP_AT
        if STOP_AT is None:
            STOP_AT = time.monotonic()
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
        print("Backup operation failed: " + safe_error(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
