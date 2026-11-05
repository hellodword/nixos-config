#!/usr/bin/env python3
"""Session-local, transition-only notifications without private journal content."""
import argparse
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
args = parser.parse_args()
if args.status:
    counts = [str(len(previous[scope])) if scope in previous else "?" for scope in ("system", "user")]
    print(f"Failed {counts[0]}/{counts[1]}")
    sys.exit(0)
current = {}
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
        current["backup"] = sorted(
            name for name, value in health["repositories"].items()
            if any(value[operation]["state"] != "fresh" for operation in ("backup", "check", "canaryRestore")))
        if not health["repositories"] or time.time() - health["generated"] > 2 * 3600:
            current["backup"] = ["status-unavailable"]
    except (OSError, ValueError, KeyError, TypeError):
        current["backup"] = ["status-unavailable"]
    if current["backup"] and current["backup"] != previous.get("backup"):
        subprocess.run(["notify-send", "-u", "critical", "备份需要检查",
                        "请运行 backup-status 查看各仓库的备份、分区校验和 canary 恢复状态。"], check=False)
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
