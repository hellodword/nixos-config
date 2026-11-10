#!/usr/bin/env python3
"""Session-local, transition-only notifications without private journal content."""
import argparse
import html
import json
import os
from pathlib import Path
import subprocess
import sys
import time

state = Path(os.environ["XDG_RUNTIME_DIR"]) / "desktop-health.json"
try:
    previous = json.loads(state.read_text())
except (OSError, ValueError):
    previous = {}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--status", action="store_true", help="show the latest system/user failed-unit counts")
parser.add_argument("--waybar", action="store_true", help="show failed-unit counts and names as Waybar JSON")
args = parser.parse_args()
if args.status or args.waybar:
    counts = [str(len(previous[scope])) if scope in previous else "?" for scope in ("system", "user")]
    text = f"Failed {counts[0]}/{counts[1]}"
    if args.waybar:
        details = []
        for scope in ("system", "user"):
            names = previous.get(scope)
            details.append(scope.capitalize() + ": " + (
                "not sampled yet" if names is None else "\n" + "\n".join(names) if names else "no failed units"))
        print(json.dumps({"text": text, "tooltip": html.escape("\n\n".join(details))}))
    else:
        print(text)
    sys.exit(0)
current = {}
if os.environ.get("SITE_NETWORK_RULES_ENABLED") == "1":
    current["rulesSession"] = os.environ.get("XDG_SESSION_ID")
    try:
        pending_rules = json.loads(Path("/run/site-network-rules/status.json").read_text()).get("pending")
        current["rules"] = pending_rules["id"] if pending_rules else None
    except (FileNotFoundError, ValueError, KeyError):
        current["rules"] = None
    if (current["rules"] != previous.get("rules") or
            current["rules"] and current["rulesSession"] != previous.get("rulesSession")):
        subprocess.run(["systemctl", "--user", "--no-block", "restart" if current["rules"] else "stop",
                        "site-network-rules-notify.service"], check=False)
levels = []
for battery in Path("/sys/class/power_supply").glob("*"):
    try:
        if (battery / "type").read_text().strip() != "Battery":
            continue
        if (battery / "status").read_text().strip() != "Discharging":
            continue
        levels.append(int((battery / "capacity").read_text()))
    except (OSError, ValueError):
        continue
if levels:
    current["battery"] = "critical" if min(levels) <= 50 else "warning" if min(levels) <= 60 else "normal"
    if current["battery"] != previous.get("battery") and current["battery"] != "normal":
        subprocess.run(["notify-send", "-u", "critical", "电量不足", f"剩余 {min(levels)}%，请连接电源。"], check=False)
if os.environ.get("SITE_BACKUP_ENABLED") == "1":
    try:
        health = json.loads(Path("/run/site-backup/status.json").read_text())
        labels = {"backup": "备份", "check": "校验", "canaryRestore": "恢复抽检", "maintenance": "空间回收"}
        states = {"failed": "失败", "stale": "超期", "unknown": "状态不可用"}
        current["backup"] = sorted(
            f"{name}：{labels[operation]}{states[value[operation]['state']]}"
            for name, value in health["repositories"].items() for operation in labels
            if value[operation]["state"] in states)
        if not health["repositories"] or time.time() - health["generated"] > 2 * 3600:
            current["backup"] = ["备份状态暂不可用"]
    except (OSError, ValueError, KeyError, TypeError):
        current["backup"] = ["备份状态暂不可用"]
    if current["backup"] and current["backup"] != previous.get("backup"):
        subprocess.run(["notify-send", "-u", "critical", "备份需要检查",
                        "\n".join(current["backup"]) + "\n运行 backup-status 查看详情。"], check=False)
for scope in ("system", "user"):
    command = ["systemctl", *(["--user"] if scope == "user" else []), "list-units", "--failed", "--plain", "--no-legend", "--no-pager"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        units = sorted(line.split()[0] for line in result.stdout.splitlines() if line.strip())
        current[scope] = units
        if units and units != previous.get(scope):
            subprocess.run(["notify-send", "-u", "critical", "服务运行异常", f"{scope}: {len(units)} 个失败单元。请用 systemctl --failed 查看。"], check=False)
temporary = state.with_suffix(".tmp")
temporary.write_text(json.dumps(current))
os.replace(temporary, state)
