"""Persistent backup records shared by execution, health and notification delivery."""
import fcntl
import json
import os
import re
import tempfile

OPERATIONS = ("backup", "check", "restore-test", "maintenance")


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


def success_path(state, operation):
    return state / (("restore" if operation == "restore-test" else operation) + "-success.json")


def attempt(state, operation):
    # Older installations have only result records. A skipped trigger must not
    # overwrite the clock of the last operation that actually started.
    for suffix in ("attempt", "result"):
        record = read_record(state / f"{operation}-{suffix}.json")
        if isinstance(record.get("started"), (int, float)):
            return record
    return {}


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
