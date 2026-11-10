"""Offer a shared-rule update without interrupting the current session."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys


def pending(status):
    return json.loads(status.read_text()).get("pending")


def review(args):
    update = pending(args.status)
    if not update:
        return 0
    notification = subprocess.Popen([
        args.notify_send, "--app-name=Network rules", "--expire-time=0",
        "--action=default=查看更新", "--action=review=查看更新", "--action=later=稍后",
        "网络规则待应用", "规则已下载并校验，等待确认后应用。\n"
        + ("中键点击查看。" if os.environ.get("XDG_CURRENT_DESKTOP") == "i3" else "点击查看更新。")],
        stdout=subprocess.PIPE, text=True)
    try:
        action = notification.communicate()[0].strip()
        if notification.returncode:
            return notification.returncode
    finally:
        if notification.poll() is None:
            notification.send_signal(signal.SIGINT)
            notification.wait()
    if action not in {"default", "review"}:
        return 0
    while update := pending(args.status):
        answer = subprocess.run([
            args.rofi, "-dmenu", "-no-custom", "-format", "i", "-selected-row", "0",
            "-p", "网络规则", "-mesg", "应用将重启 DNS 与代理服务，现有连接可能需要重连。"],
            input="稍后\n立即应用\n", text=True, capture_output=True)
        if answer.returncode or answer.stdout.strip() != "1":
            return 0
        if pending(args.status) != update:
            continue
        unit = "site-network-rules-apply@" + update["id"] + ".service"
        applied = subprocess.run([args.systemctl, "start", unit], text=True, capture_output=True)
        status = json.loads(args.status.read_text())
        success = applied.returncode == 0 and (status.get("active") or {}).get("id") == update["id"]
        subprocess.run([args.notify_send, "--app-name=Network rules",
                        "网络规则已应用" if success else "网络规则尚未应用",
                        "DNS 与连接路由已同步。" if success else f"可稍后重试；详情：journalctl -u {unit}"], check=False)
        if not success:
            print(applied.stderr, file=sys.stderr)
            return 1
        return 0
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", type=Path, default=Path("/run/site-network-rules/status.json"))
    parser.add_argument("--notify-send", default="notify-send")
    parser.add_argument("--rofi", default="rofi")
    parser.add_argument("--systemctl", default="systemctl")
    args = parser.parse_args()
    try:
        return review(args)
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Network rule notification: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
