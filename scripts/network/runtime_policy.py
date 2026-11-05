#!/usr/bin/env python3
"""Validate and apply local domain overrides without changing network protection."""
import argparse
import fcntl
import grp
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

import domain_policy
import dns_policy as compiler
import assemble as assembler
import render as renderer
import ipv6
SERVICE_FILES = {
    "sing-box.service": ["network.json", "provider.json"],
    "site-dns.service": ["dnsdist.conf"],
    "site-dns-race-cn.service": ["race-cn.json"],
    "site-dns-race-global.service": ["race-global.json"],
}
WATCHER = "site-network-underlay.service"


def command(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, timeout=120)


def prepare(args, stage):
    policy = json.loads(args.policy.read_text())
    if args.base:
        base = json.loads(args.base.read_text())
        policy["connectionFragments"] = base.get("_connectionFragments", {}) | policy.get("connectionFragments", {})
    model = domain_policy.compile_policy(policy, args.fragments, args.connections, include_connections=bool(args.sing_box))
    (stage / "summary.json").write_text(json.dumps(model["summary"], indent=2) + "\n")
    services = []
    listeners = {}
    transports = []
    if args.dnsdist:
        listeners["site-dns.service"] = compiler.compile_policy(policy, stage, model, args.ipv4_only)
        command(args.dnsdist, "--check-config", "-C", str(stage / "dnsdist.conf"))
        transports = json.loads((stage / "transports.json").read_text())
        services.extend(unit for unit in SERVICE_FILES if unit != "sing-box.service")
        for group in ("cn", "global"):
            race = json.loads((stage / f"race-{group}.json").read_text())
            listeners[f"site-dns-race-{group}.service"] = [
                (address, port) for address in race["listen-addrs"] for port in race["listen-ports"]]
    if args.sing_box:
        network = assembler.assemble(json.loads(args.base.read_text()), policy, transports, model, args.ipv4_only)
        (stage / "network.json").write_text(json.dumps(network) + "\n")
        listeners["sing-box.service"] = [(inbound["listen"], inbound["listen_port"])
                                         for inbound in network["inbounds"] if inbound.get("network") != "udp"]
        provider = stage / "provider.json"
        if args.provider.exists():
            # systemd loads the generation's immutable credential before dropping
            # privileges. DNS workers share policy access, not proxy credentials.
            provider.write_bytes(args.provider.read_bytes())
            provider.chmod(0o600)
        validation_provider = provider
        if args.bootstrap and not provider.exists():
            validation_provider = stage / ".schema-provider.json"
            validation_provider.write_text(json.dumps({"outbounds": [{"type": "http", "tag": "schema-check", "server": "192.0.2.1", "server_port": 443}]}))
        try:
            renderer.render(stage / "network.json", validation_provider, stage / ".validated.json", args.sing_box,
                            wireguard_key=args.wireguard_key, wireguard_peer=args.wireguard_peer)
        finally:
            (stage / ".validated.json").unlink(missing_ok=True)
            (stage / ".schema-provider.json").unlink(missing_ok=True)
        services.append("sing-box.service")
    manifest = {}
    for unit in services:
        manifest[unit] = {filename: hashlib.sha256((stage / filename).read_bytes()).hexdigest()
                          if (stage / filename).exists() else None for filename in SERVICE_FILES[unit]}
    (stage / "activation.json").write_text(json.dumps(manifest) + "\n")
    (stage / "listeners.json").write_text(json.dumps(listeners) + "\n")
    (stage / "ipv6-mode.json").write_text(json.dumps({"ipv4_only": args.ipv4_only}) + "\n")


def finish_stage(stage, group):
    gid = grp.getgrnam(group).gr_gid
    for path in stage.iterdir():
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("generated policy must contain regular files")
        os.chown(path, -1, gid)
        path.chmod(0o600 if path.name == "provider.json" else 0o640)
    os.chown(stage, -1, gid)
    stage.chmod(0o750)


def publish(root, generation):
    pending = root / ".current-next"
    pending.unlink(missing_ok=True)
    pending.symlink_to(generation.name)
    os.replace(pending, root / "current")


def ready(generation, units, run):
    """Require live, stable processes and their local TCP listeners within 30s."""
    listeners = json.loads((generation / "listeners.json").read_text())
    deadline = time.monotonic() + 30
    stable_since, previous = None, None
    pending = []
    while time.monotonic() < deadline:
        processes = []
        pending.clear()
        for unit in units:
            output = run("systemctl", "show", "--property=ActiveState,MainPID,NRestarts", unit).stdout.decode()
            state = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
            if state.get("ActiveState") == "failed" or int(state.get("NRestarts", 0)) > 0:
                raise ValueError(f"{unit} failed during policy activation")
            if state.get("ActiveState") != "active" or state.get("MainPID", "0") == "0":
                pending.append(
                    f"{unit}: state={state.get('ActiveState', 'unknown')}, MainPID={state.get('MainPID', '0')}"
                )
            processes.append(state.get("MainPID"))
            for address, port in listeners[unit]:
                try:
                    with socket.create_connection((address, port), timeout=0.2):
                        pass
                except OSError as error:
                    pending.append(f"{unit} [{address}]:{port}: {error}")
        now = time.monotonic()
        if not pending:
            if stable_since is None or processes != previous:
                stable_since = now
            elif now - stable_since >= 2:
                return
        else:
            stable_since = None
        previous = processes
        time.sleep(0.2)
    detail = "; ".join(pending) or "service processes did not remain stable for 2 seconds"
    raise ValueError(f"Policy services did not become locally ready within 30 seconds: {detail}")


def activate(root, stage, watch, run=command, wait_ready=ready, consumers=None, restart_all=False):
    current = root / "current"
    previous = current.resolve(strict=True)
    if previous.parent != root or not previous.name.startswith("generation-"):
        raise ValueError("unexpected active generation")
    before = json.loads((previous / "activation.json").read_text())
    after = json.loads((stage / "activation.json").read_text())
    allowed = set(consumers if consumers is not None else SERVICE_FILES)
    if set(after) != allowed:
        raise ValueError("generation does not match the declared policy consumers")
    changed, active = [], []
    for unit in after:
        state = run("systemctl", "show", "--property=ActiveState", "--value", unit).stdout.decode().strip()
        # Restart=on-failure spends its delay in activating, not failed. An
        # explicit apply must finish that recovery before reporting success.
        recovering = state in {"failed", "activating"}
        if before.get(unit) != after[unit] or recovering or restart_all:
            changed.append(unit)
            if restart_all or state in {"active", "reloading", "activating", "failed"}:
                active.append(unit)
    watching = (watch and "sing-box.service" in changed and
                run("systemctl", "is-active", "--quiet", WATCHER, check=False).returncode == 0)
    if watching:
        run("systemctl", "stop", WATCHER)
    try:
        if changed:
            run("systemctl", "stop", *changed)
            run("systemctl", "reset-failed", *changed)
        publish(root, stage)
        try:
            if active:
                run("systemctl", "start", *active)
                wait_ready(stage, active, run)
        except (OSError, ValueError, subprocess.SubprocessError):
            run("systemctl", "stop", *changed)
            run("systemctl", "reset-failed", *changed)
            publish(root, previous)
            if active:
                run("systemctl", "start", *active)
                wait_ready(previous, active, run)
            raise
    finally:
        if watching:
            run("systemctl", "start", WATCHER)
    return previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["bootstrap", "check", "apply", "prepare", "ipv6", "reconcile"])
    parser.add_argument("mode", nargs="?", choices=["off", "restore", "status"])
    parser.add_argument("--ipv4-only", action="store_true")
    parser.add_argument("--tailscale", action="store_true")
    for flag in ("policy", "root"):
        parser.add_argument("--" + flag, type=Path, required=True)
    parser.add_argument("--fragments", type=Path)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--connections", type=Path)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--bootstrap", action="store_true")
    parser.add_argument("--prepare-command", required=False)
    parser.add_argument("--provider", type=Path)
    parser.add_argument("--dnsdist")
    parser.add_argument("--sing-box")
    parser.add_argument("--wireguard-key", type=Path)
    parser.add_argument("--wireguard-peer", type=Path)
    parser.add_argument("--group", required=True)
    parser.add_argument("--watch-underlay", action="store_true")
    args = parser.parse_args()
    if args.action == "ipv6" and args.mode is None:
        args.mode = "status"
    if not (args.dnsdist or args.sing_box):
        parser.error("select DNS or sing-box")
    if args.sing_box and not (args.base and args.provider):
        parser.error("sing-box requires --base and --provider")
    if os.geteuid() != 0:
        parser.exit(1, "network-policy requires root\n")
    if args.action == "prepare":
        prepare(args, args.stage)
        return 0
    stage = None
    consumers = (["site-dns.service", "site-dns-race-cn.service", "site-dns-race-global.service"] if args.dnsdist else []) + (["sing-box.service"] if args.sing_box else [])
    try:
        if args.action == "ipv6" and args.mode == "status":
            return ipv6.status(args.root, consumers, args.watch_underlay, args.tailscale)
        with (args.root / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.action == "reconcile":
                ipv6.reconcile(args.root)
                return 0
            args.ipv4_only = args.mode == "off" if args.action == "ipv6" else ipv6.ipv4_only(args.root)
            stage = Path(tempfile.mkdtemp(prefix="generation-", dir=args.root))
            if not args.prepare_command:
                raise ValueError("a sandboxed preparation command is required")
            try:
                command(args.prepare_command, str(stage), args.action, "ipv4" if args.ipv4_only else "dual")
            except subprocess.CalledProcessError as error:
                fd = os.open(args.root / "last-prepare.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as log:
                    log.write((error.stdout or b"") + (error.stderr or b""))
                raise ValueError("Candidate validation failed; inspect the protected last-prepare.log") from error
            finish_stage(stage, args.group)
            if args.action == "bootstrap":
                publish(args.root, stage)
            elif args.action == "ipv6":
                previous = ipv6.transition(args.root, args.ipv4_only,
                    lambda: activate(args.root, stage, False, consumers=consumers, restart_all=True),
                    lockdown=args.watch_underlay, tailscale=args.tailscale)
                shutil.rmtree(previous)
                return ipv6.status(args.root, consumers, args.watch_underlay, args.tailscale)
            elif args.action == "apply":
                previous = activate(args.root, stage, args.watch_underlay, consumers=consumers)
                shutil.rmtree(previous)
            summary = json.loads((stage / "summary.json").read_text())
            print(("Validated " if args.action == "check" else "Applied ") + summary["generation"])
            if args.sing_box:
                summary = summary | summary["connection"]
            for item in summary["files"]:
                print(f"  {item['file']} ({item['source']})")
            for item in summary["rules"]:
                print(f"  {item['rule']} -> {item['outbound']}")
            print(f"  {summary['final_source']} -> {summary['final']}")
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, KeyError, TypeError, subprocess.SubprocessError):
        print("Policy operation failed; inspect local inputs, service status and network-ipv6 status.", file=sys.stderr)
        return 1
    finally:
        if stage is not None and (args.root / "current").resolve() != stage:
            shutil.rmtree(stage)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
