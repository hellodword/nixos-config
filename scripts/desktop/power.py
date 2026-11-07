"""Rofi session actions with application and backup workload checks."""
import argparse
from collections import defaultdict
import os
from pathlib import Path
import re
import subprocess
import sys


ACTIONS = ("Log out", "Reboot", "Power off")
APPLICATIONS = {
    "firefox": "Firefox", "firefox-bin": "Firefox",
    "chrome": "Chrome", "google-chrome": "Chrome", "google-chrome-stable": "Chrome",
    "chromium": "Chromium", "chromium-browser": "Chromium",
    "code": "VS Code", "bitwarden": "Bitwarden",
}
BACKUP_UNIT = re.compile(r"site-backup-.+-(automatic|backup|check|restore-test|maintenance)\.service")


def executable_name(value):
    return Path(value).name.removeprefix(".").removesuffix("-wrapped").lower()


def process_blockers(system_action):
    groups = defaultdict(list)
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            status = dict(line.split(":", 1) for line in (process / "status").read_text().splitlines() if ":" in line)
            uid = int(status["Uid"].split()[0])
            if status["State"].split()[0] == "Z" or (uid != os.getuid() and not system_action):
                continue
            argv = (process / "cmdline").read_bytes().rstrip(b"\0").decode(errors="replace").split("\0")
            if not argv[0]:
                continue
            names = {executable_name(argv[0])}
            # The sandbox supervisor retains the launched application's
            # identity even when the application restricts its own procfs data.
            if "firejail" in names and "--" in argv:
                command_index = argv.index("--") + 1
                if command_index < len(argv):
                    names.add(executable_name(argv[command_index]))
            # Sandboxed or other-user processes can deny readlink while their
            # public argv remains readable. Never print their command lines.
            try:
                names.add(executable_name(os.readlink(process / "exe")))
            except PermissionError:
                pass
            label = None
            if any(name.startswith("qemu-system-") for name in names):
                label = "QEMU"
            elif names & {"virtualboxvm", "vboxheadless"}:
                label = "VirtualBox"
            elif uid == os.getuid():
                label = next((APPLICATIONS[name] for name in sorted(names) if name in APPLICATIONS), None)
                if label is None and any(name.startswith("electron") for name in names):
                    if any(value.endswith("/opt/Bitwarden/resources/app.asar") for value in argv[1:]):
                        label = "Bitwarden"
            if label:
                groups[label].append(int(process.name))
        except (FileNotFoundError, ProcessLookupError):
            # A process may finish between any two procfs reads.
            continue
    return [f"{label}: {len(pids)} process(es), PID " + ", ".join(map(str, sorted(pids)[:6]))
            + (", …" if len(pids) > 6 else "") for label, pids in sorted(groups.items())]


def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=15, env={**os.environ, "LC_ALL": "C"}).stdout


def backup_blockers(systemctl):
    units = {}
    output = run([systemctl, "--system", "--no-pager", "--no-legend", "--plain",
                  "list-units", "--all", "--type=service", "site-backup-*"])
    for line in output.splitlines():
        name, _load, active, sub, *_ = line.split()
        if BACKUP_UNIT.fullmatch(name) and active not in {"inactive", "failed"}:
            units[name] = f"{active}/{sub}"
    output = run([systemctl, "--system", "--no-pager", "--no-legend", "--plain", "list-jobs"])
    for line in output.splitlines():
        _job, name, operation, state, *_ = line.split()
        if BACKUP_UNIT.fullmatch(name):
            units[name] = f"{operation}/{state}"
    return [f"{name}: {state}" for name, state in sorted(units.items())]


def choose(rofi, prompt, choices):
    result = subprocess.run([rofi, "-dmenu", "-no-custom", "-format", "i", "-selected-row", "0",
                             "-p", prompt], input="\n".join(choices) + "\n", text=True, capture_output=True)
    if result.returncode == 1:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not open the session menu")
    return choices[int(result.stdout.strip())]


def message(rofi, text):
    subprocess.run([rofi, "-e", text], check=False)


def logout_command(args):
    desktops = os.environ.get("XDG_CURRENT_DESKTOP", "").split(":")
    if "sway" in desktops:
        return [args.swaymsg, "exit"]
    if "i3" in desktops:
        return [args.i3msg, "exit"]
    if "KDE" in desktops:
        return [args.busctl, "--user", "call", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown", "logout"]
    raise RuntimeError("This desktop has no configured logout action")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("rofi", "systemctl", "swaymsg", "i3msg", "busctl"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        action = choose(args.rofi, "Session", ACTIONS)
        if action is None:
            return 0
        system_action = action != "Log out"
        command = ([args.systemctl, "--check-inhibitors=yes", "reboot" if action == "Reboot" else "poweroff"]
                   if system_action else logout_command(args))
        for confirmed in (False, True):
            blockers = process_blockers(system_action)
            if system_action:
                blockers += backup_blockers(args.systemctl)
            if blockers:
                message(args.rofi, action + " is waiting for:\n\n" + "\n".join(blockers)
                        + "\n\nClose these applications or wait for the tasks, then try again.")
                return 0
            if not confirmed and choose(args.rofi, action, ("Cancel", action)) != action:
                return 0
        run(command)
        return 0
    except (OSError, ValueError, IndexError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(f"desktop-power: {detail}", file=sys.stderr)
        message(args.rofi, "Could not complete the session action:\n\n" + detail)
        return 1


if __name__ == "__main__":
    sys.exit(main())
