"""Automatic execution windows and due times; no repository or power queries."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from state import OPERATIONS, attempt, read_record, success_path


def window_at(schedule, now, offset=0):
    local = datetime.fromtimestamp(now, ZoneInfo(schedule["timeZone"]))
    minute = local.hour * 60 + local.minute
    for window in schedule["windows"]:
        start, end = (sum(int(v) * factor for v, factor in zip(window[key].split(":"), (60, 1)))
                      for key in ("start", "end"))
        if start + offset <= minute < end:
            return window | {"id": f"{local.date()}:{window['start']}:{window['end']}"}
    return None


def recent(state, operation, metadata, policy, now):
    previous = read_record(success_path(state, operation))
    interval = policy.get("minimumIntervalSeconds", {}).get(operation, 0)
    return (previous.get("scope") == metadata["scope"]
            and isinstance(previous.get("time"), (int, float))
            and 0 <= now - previous["time"] < interval)


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
