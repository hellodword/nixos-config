#!/usr/bin/env python3
"""Select, back up and verify explicit paths with Restic.

Paths in the policy are relative to source. Selections and exclusions are root-relative shell
patterns (fnmatchcase: * also matches /), or exact component names per root.
Symlinks are saved as links, never traversed. Selection fails on unreadable
paths, required missing roots and mount boundaries.
"""
import argparse
from datetime import datetime, timedelta
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
from zoneinfo import ZoneInfo


OPERATIONS = ("backup", "check", "restore-test", "maintenance")
STOP_AT = None


class Interrupted(Exception):
    def __init__(self, code=None):
        self.code = code


class ResticError(RuntimeError):
    def __init__(self, code, detail):
        self.code = code
        self.detail = safe_error(detail)
        super().__init__(f"Restic failed (exit {code}): {self.detail}")


def safe_error(message):
    """Bound public diagnostics; URLs, paths and credential values stay private."""
    text = str(message)
    for name, value in os.environ.items():
        if value and re.search(r"PASSWORD|TOKEN|SECRET|ACCESS_KEY|CREDENTIAL|AUTH", name, re.I):
            text = text.replace(value, "[credential]")
    text = re.sub(r"(?:[a-z][a-z0-9+.-]*://|(?:s3|b2|rest|sftp):)[^\s\"'<>]+", "[repository]", text, flags=re.I)
    text = re.sub(r"(?i)\b(password|token|secret|authorization|access[_-]?key)(\s*[=:]\s*)\S+", r"\1\2[credential]", text)
    text = re.sub(r"(?<!\w)/(?:[^\s\"'<>]+)", "[path]", text)
    text = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', text)
    return " ".join(text.split())[:512] or "see protected command log"


def check_interrupted():
    if STOP_AT is not None:
        raise Interrupted()


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
            if k not in ("schedule", "minimumIntervalSeconds", "automatic", "health", "recoverStaleLocks")}
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
            raise ResticError(code, error or tail.decode(errors="replace"))
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


def recover_locks(binary, state):
    """Only an explicitly single-host repository may remove proven dead local locks."""
    def inspect(arguments):
        return restic_command(binary, ["--no-lock", "--quiet", *arguments], state,
                              capture=True, log_name="lock-recovery.log")

    ids = inspect(["list", "locks"]).decode().splitlines()
    if any(not re.fullmatch(r"[0-9a-f]{64}", identity) for identity in ids):
        raise RuntimeError("cannot inspect repository locks")
    for identity in ids:
        lock = json.loads(inspect(["cat", "lock", identity]))
        pid = lock.get("pid")
        if lock.get("hostname") != socket.gethostname() or type(pid) is not int or pid <= 0:
            raise RuntimeError("repository lock owner cannot be verified locally")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
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


def backup(args, policy, metadata, common):
    plan = select(args.source, policy)
    with tempfile.NamedTemporaryFile(dir=args.state) as files:
        for name in plan["paths"]:
            files.write(os.fsencode(name) + b"\0")
        files.flush()
        # Stable host/tag grouping lets Restic select an existing parent
        # when the exact file list changes.
        summary = restic(args.restic, ["backup", "--json", "--host", policy["host"], *common, "--group-by", "host,tags", "--files-from-raw", files.name], args.state, cwd=args.source,
                         recover_stale_locks=policy.get("recoverStaleLocks", False))
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


def attempt(state, operation, metadata):
    # Older installations have only result records. A skipped trigger must not
    # overwrite the clock of the last operation that actually started.
    for suffix in ("attempt", "result"):
        record = read_record(state / f"{operation}-{suffix}.json")
        if record.get("scope") == metadata["scope"] and isinstance(record.get("started"), (int, float)):
            return record
    return {}


def next_window(schedule, earliest, offset, *, heavy=False):
    zone = ZoneInfo(schedule["timeZone"])
    local = datetime.fromtimestamp(earliest, zone)
    windows = [w for w in schedule["windows"] if not heavy or w["maintenance"]]
    for days in range(3):
        day = local.date() + timedelta(days=days)
        candidates = []
        for window in windows:
            start = datetime.combine(day, datetime.strptime(window["start"], "%H:%M").time(), zone) + timedelta(minutes=offset)
            end = datetime.combine(day, datetime.strptime(window["end"], "%H:%M").time(), zone)
            when = max(earliest, start.timestamp())
            if when < end.timestamp():
                candidates.append(when)
        if candidates:
            return int(min(candidates))
    return None


def automatic_decision(state, operation, metadata, policy, now, offset=0):
    """Earliest policy-eligible time, without querying the repository or power state."""
    automatic = policy.get("automatic", {})
    if not automatic.get("enable", True):
        return {"nextEligibleAt": None, "reason": "automatic execution disabled"}
    schedule = policy.get("schedule")
    if not schedule:
        return {"nextEligibleAt": None, "reason": "no automatic windows"}
    heavy = operation != "backup"
    constraints = [(int(now), "ready")]
    previous = read_record(success_path(state, operation))
    if previous.get("scope") == metadata["scope"]:
        constraints.append((previous.get("time", 0) + policy.get("minimumIntervalSeconds", {}).get(operation, 0), "recent successful run"))
    last = attempt(state, operation, metadata)
    if last.get("result") in ("failure", "interrupted", "running"):
        retry = automatic.get("retryIntervalSeconds", {}).get(operation, 900 if not heavy else 86400)
        constraints.append((last.get("finished", last["started"]) + retry, "retry interval"))
    if heavy:
        started = max((attempt(state, op, metadata).get("started", 0) for op in OPERATIONS[1:]), default=0)
        constraints.append((started + automatic.get("heavySpacingSeconds", 0), "heavy operation spacing"))
    else:
        window = window_at(schedule, now, offset)
        if window:
            counted = read_record(state / "backup-window.json")
            maximum = automatic.get("backupAttemptsPerWindow")
            reason = None
            if previous.get("scope") == metadata["scope"] and previous.get("window") == window["id"]:
                reason = "backup already completed in this window"
            elif (maximum is not None and counted.get("scope") == metadata["scope"]
                  and counted.get("window") == window["id"] and counted.get("count", 0) >= maximum):
                reason = "backup attempt limit for this window"
            elif (maximum == 1 and last.get("window") == window["id"]):
                # Existing result records also consume an attempt on upgrade.
                reason = "backup attempt limit for this window"
            if reason:
                local = datetime.fromtimestamp(now, ZoneInfo(schedule["timeZone"]))
                end = datetime.combine(local.date(), datetime.strptime(window["end"], "%H:%M").time(), local.tzinfo)
                constraints.append((end.timestamp(), reason))
    earliest, reason = max(constraints, key=lambda item: item[0])
    eligible = next_window(schedule, earliest, offset, heavy=heavy)
    if earliest == int(now) and eligible != int(now):
        reason = "outside maintenance window" if heavy else "outside backup window"
    return {"nextEligibleAt": eligible, "reason": reason}


def record_result(state, record):
    operation = record["operation"]
    atomic_json(state / f"{operation}-result.json", record)
    if operation in OPERATIONS and "started" in record:
        atomic_json(state / f"{operation}-attempt.json", record)
    if record["result"] == "skipped":
        return
    # Delivery acknowledges only the same event it read. The lock is held for
    # local updates, never across a network request or a Restic operation.
    with (state / "notifications.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        atomic_json(state / f"{operation}-pending.json", record | {"deliveredChannels": []})


def run_operation(args, policy, metadata, operation, *, checked=False, reuse_backup=False):
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
        count = counted.get("count", 0) if all(counted.get(k) == metadata[k] for k in ("scope", "window")) else 0
        atomic_json(args.state / "backup-window.json", metadata | {"count": count + 1})

    def command(arguments):
        return restic(args.restic, arguments, args.state,
                      recover_stale_locks=policy.get("recoverStaleLocks", False))

    common = ["--tag", "site:" + policy["host"]]
    try:
        if operation == "backup":
            phase("selection-and-backup")
            backup(args, policy, metadata, common)
        elif operation == "check":
            parts = policy.get("checkPartitions", 12)
            old = read_record(success_path(args.state, operation))
            part = old.get("nextPartition", 1) if old.get("partitions") == parts and old.get("scope") == metadata["scope"] else 1
            command(["check", f"--read-data-subset={part}/{parts}"])
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
                    backup(args, policy, metadata, common)
                if not checked:
                    phase("check-before-prune")
                    command(["check"])
                if reuse_backup:
                    window = window_at(policy["schedule"], time.time(), args.offset_minutes)
                    if not window or window["id"] != metadata["window"] or not window["maintenance"] or not on_ac_power():
                        record.update(result="skipped", reason="awaiting maintenance window and AC power")
                        return
                phase("forget-and-prune")
            command(["forget", *( ["--prune"] if operation == "maintenance" else ["--dry-run"] ),
                     *common, "--host", policy["host"], "--group-by", "host,tags", *policy["retention"]])
            if operation == "maintenance":
                phase("check-after-prune")
                command(["check"])
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
    args.offset_minutes = (args.offset_minutes if args.offset_minutes is not None
                           else policy.get("schedule", {}).get("offsetMinutes", 0))
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
        if not policy.get("automatic", {}).get("enable", True):
            return "automatic execution disabled"
        if window is None:
            return "outside backup window"
        previous = read_record(success_path(args.state, "backup"))
        completed = False
        if previous.get("scope") != metadata["scope"] or previous.get("window") != window["id"]:
            decision = automatic_decision(args.state, "backup", metadata, policy, time.time(), args.offset_minutes)
            if decision["nextEligibleAt"] is None or decision["nextEligibleAt"] > time.time():
                return decision["reason"]
            run_operation(args, policy, metadata, "backup")
            completed = True
        checked = False
        order = sorted(OPERATIONS[1:], key=lambda op: attempt(args.state, op, metadata).get("started", 0))
        for operation in order:
            check_interrupted()
            current = window_at(schedule, time.time(), args.offset_minutes)
            if not current or current["id"] != window["id"] or not current["maintenance"] or not on_ac_power():
                break
            decision = automatic_decision(args.state, operation, metadata, policy, time.time(), args.offset_minutes)
            if decision["nextEligibleAt"] is None or decision["nextEligibleAt"] > time.time():
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
    parser.add_argument("--force", action="store_true", help="ignore the manual operation's minimum interval; automatic policy and locks still apply")
    parser.add_argument("--offset-minutes", type=int, help="override the policy's window offset")
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
