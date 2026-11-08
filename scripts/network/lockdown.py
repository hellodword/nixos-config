#!/usr/bin/env python3
"""Prepare local tunnel identity, capture routes and Mullvad protection settings."""
import argparse
import base64
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import ipv6

CLIENT4, CLIENT6 = "10.67.0.2", "fd66:105::2"
GATE4, GATE6 = "10.67.0.1", "fd66:105::1"
OWNER = "site-network-routing-v1"
# Locked Mullvad 2026.5 constants. Its main-table suppression rule otherwise
# lets connected/static routes avoid the tunnel and hit the LAN reject rule.
TUNNEL_TABLE = 0x6D6F6C65
# Mullvad deletes any inverted-fwmark lookup of its table while connecting,
# regardless of priority. Positive rules keep our independently owned routing
# intact: infrastructure uses main first, remaining traffic uses the tunnel.
CAPTURE_RULES = (
    (100, ("fwmark", TUNNEL_TABLE, "lookup", "main")),
    (101, ("lookup", TUNNEL_TABLE)),
)


def run(args, *, data=None, check=True):
    result = subprocess.run(list(map(str, args)), input=data, text=True, capture_output=True, timeout=30)
    if check and result.returncode:
        # CLI diagnostics can include configuration; log only the operation.
        raise RuntimeError(f"network operation failed: {args[0]}")
    return result


def atomic(path, text):
    if path.is_symlink():
        raise ValueError("refusing a symlink state file")
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".pending-")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def capture_rules(action):
    for family in (("-4",) if action == "add" and ipv6.ipv4_only() else ("-4", "-6")):
        entries = CAPTURE_RULES if action == "add" else reversed(CAPTURE_RULES)
        for priority, selector in entries:
            result = run(["ip", family, "rule", action, "priority", priority, *selector],
                         check=action == "add")
            if action == "del" and result.returncode:
                rules = json.loads(run(["ip", family, "-j", "rule", "show"]).stdout)
                if any(rule.get("priority") == priority for rule in rules):
                    raise ValueError("cannot release the owned policy rule")


def prepare(state):
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.is_symlink() or stat.S_IMODE(state.stat().st_mode) & 0o077:
        raise ValueError("network state must be a private real directory")
    for name in ("client", "gateway"):
        path = state / f"{name}.key"
        if not path.exists():
            atomic(path, run(["wg", "genkey"]).stdout)
        if path.is_symlink() or stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise ValueError("unsafe WireGuard key file")
        if len(base64.b64decode(path.read_text().strip(), validate=True)) != 32:
            raise ValueError("invalid WireGuard key")
    atomic(state / "client.pub", run(["wg", "pubkey"], data=(state / "client.key").read_text()).stdout)
    settings = state / "mullvad"
    settings.mkdir(mode=0o700, exist_ok=True)
    path = settings / "settings.json"
    if path.exists():
        # Never edit a running daemon's persisted settings. Re-enable via CLI
        # after startup; the independent early blocker remains in force.
        data = json.loads(path.read_text())
        if data.get("settings_version") != 17 or not data.get("lockdown_mode") or data.get("allow_lan"):
            raise ValueError("Mullvad settings differ from the validated protected state; refusing daemon startup")
    else:
        # The locked 2026.5 schema uses serde(default), CURRENT_SETTINGS_VERSION=17.
        # Seed BEFORE its first daemon start, so early blocking cannot be cleared
        # by an initially disconnected daemon with the default Lockdown=false.
        atomic(path, json.dumps({"settings_version": 17, "lockdown_mode": True,
                                "allow_lan": False, "auto_connect": False}) + "\n")


def remove(runtime):
    marker = runtime / "owner"
    if marker.exists() and marker.read_text().strip() == OWNER:
        capture_rules("del")
        marker.unlink()


def routing(runtime):
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    remove(runtime)
    for family in ("-4", "-6"):
        rules = json.loads(run(["ip", family, "-j", "rule", "show"]).stdout)
        if any(rule.get("priority") in dict(CAPTURE_RULES) for rule in rules):
            raise ValueError("policy rule priority already belongs to another service")
    atomic(runtime / "owner", OWNER + "\n")
    capture_rules("add")


def connect(state):
    only4 = ipv6.ipv4_only()
    public = run(["wg", "pubkey"], data=(state / "gateway.key").read_text()).stdout.strip()
    commands = [
        ["lockdown-mode", "set", "on"], ["lan", "set", "block"],
        # The peer is the local sing-box endpoint, also configured for 1280.
        # An explicit MTU keeps automatic probing from disabling IPv6 below 1280.
        ["tunnel", "set", "mtu", "1280"],
        ["relay", "set", "custom", "127.0.0.1", "51820", public, CLIENT4,
         *([] if only4 else [CLIENT6]), "--v4-gateway", GATE4,
         *([] if only4 else ["--v6-gateway", GATE6])],
        ["tunnel", "set", "ipv6", "off" if only4 else "on"], ["tunnel", "set", "quantum-resistant", "off"],
        # Default DNS means this custom tunnel's gateways. Custom RFC1918/ULA
        # DNS addresses are instead classified as outside-tunnel by Mullvad.
        ["dns", "set", "default"], ["auto-connect", "set", "on"], ["connect"],
    ]
    for args in commands:
        run(["mullvad", *args], data=(state / "client.key").read_text() if args[0] == "relay" else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "start", "stop", "connect"])
    parser.add_argument("--state", type=Path, default=Path("/var/lib/site-network"))
    parser.add_argument("--runtime", type=Path, default=Path("/run/site-network-routing"))
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.exit(1, "requires the system network service\n")
    try:
        {"prepare": lambda: prepare(args.state), "start": lambda: routing(args.runtime),
         "stop": lambda: remove(args.runtime), "connect": lambda: connect(args.state)}[args.action]()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        parser.exit(1, "network control operation failed; protection remains enabled\n")


if __name__ == "__main__":
    main()
