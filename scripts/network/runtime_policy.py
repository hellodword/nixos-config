#!/usr/bin/env python3
"""Validate and apply local domain overrides without changing network protection."""
import argparse
from contextlib import ExitStack, contextmanager
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
import underlay
import rules as rule_updates
SERVICE_FILES = {
    "sing-box.service": ["network.json", "provider.json"],
    "site-dns.service": ["dnsdist.conf"],
    "site-dns-race-cn.service": ["race-cn.json"],
    "site-dns-race-global.service": ["race-global.json"],
}
WATCHER = "site-network-underlay.service"


def command(*args, check=True, timeout=120):
    return subprocess.run(args, check=check, capture_output=True, timeout=timeout)


def prepare(args, stage):
    policy = json.loads(args.policy.read_text())
    if args.base:
        base = json.loads(args.base.read_text())
        policy["connectionFragments"] = base.get("_connectionFragments", {}) | policy.get("connectionFragments", {})
    model = domain_policy.compile_policy(policy, args.fragments, args.connections,
        include_connections=bool(args.sing_box), rule_paths=rule_updates.paths(args.rules_directory))
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


def ready(generation, units, run, *, wait_binding=False):
    """Require live, stable processes and their local TCP listeners within 30s."""
    listeners = json.loads((generation / "listeners.json").read_text())
    deadline = time.monotonic() + 30
    stable_since, previous = None, None
    pending = []
    while time.monotonic() < deadline:
        processes = []
        pending.clear()
        for unit in units:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                pending.append(f"{unit}: readiness deadline reached")
                break
            output = run("systemctl", "show", "--property=ActiveState,MainPID,NRestarts,Result,ExecMainStatus", unit,
                         timeout=remaining).stdout.decode()
            state = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
            if state.get("ActiveState") == "failed" or int(state.get("NRestarts", 0)) > 0:
                raise ValueError(f"{unit} failed during policy activation: "
                                 f"result={state.get('Result')}, exit={state.get('ExecMainStatus')}")
            if state.get("ActiveState") != "active" or state.get("MainPID", "0") == "0":
                pending.append(
                    f"{unit}: state={state.get('ActiveState', 'unknown')}, MainPID={state.get('MainPID', '0')}"
                )
            processes.append(state.get("MainPID"))
            for address, port in listeners[unit]:
                address = {"0.0.0.0": "127.0.0.1", "::": "::1"}.get(address, address)
                try:
                    with socket.create_connection((address, port), timeout=min(0.2, max(0.001, deadline - time.monotonic()))):
                        pass
                except OSError as error:
                    pending.append(f"{unit} [{address}]:{port}: {error}")
        if wait_binding:
            observed = underlay.observe(timeout=max(0.001, deadline - time.monotonic()))
            binding = Path("/run/site-network-underlay/underlay.json")
            if observed is None or json.loads(binding.read_text()) != observed:
                pending.append("physical route/address binding is still changing")
        now = time.monotonic()
        if not pending:
            if stable_since is None or processes != previous:
                stable_since = now
            elif now - stable_since >= 2:
                return
        else:
            stable_since = None
        previous = processes
        time.sleep(min(0.2, max(0, deadline - time.monotonic())))
    detail = "; ".join(pending) or "service processes did not remain stable for 2 seconds"
    raise ValueError(f"Policy services did not become locally ready within 30 seconds: {detail}")


@contextmanager
def recovery_step(primary):
    """Attempt every recovery step while retaining the initial failure."""
    try:
        yield
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        primary.add_note("Restoring previous policy: " + ipv6.error_summary(error))


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
    try:
        if watching:
            run("systemctl", "stop", WATCHER)
        if changed:
            run("systemctl", "stop", *changed)
            run("systemctl", "reset-failed", *changed)
        publish(root, stage)
        if active:
            run("systemctl", "start", *active)
            wait_ready(stage, active, run)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        if changed:
            with recovery_step(error):
                run("systemctl", "stop", *changed)
            with recovery_step(error):
                run("systemctl", "reset-failed", *changed)
        with recovery_step(error):
            publish(root, previous)
        if active:
            with recovery_step(error):
                run("systemctl", "start", *active)
            with recovery_step(error):
                wait_ready(previous, active, run)
        raise
    finally:
        if watching:
            primary = sys.exception()
            try:
                run("systemctl", "start", WATCHER)
            except (OSError, subprocess.SubprocessError) as cleanup:
                if primary is None:
                    raise
                primary.add_note("Restarting underlay watcher: " + ipv6.error_summary(cleanup))
    return previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["bootstrap", "check", "apply", "prepare", "ipv6", "initialize", "reconcile",
                                         "update-rules", "apply-rules", "rules-status"])
    parser.add_argument("mode", nargs="?", choices=["on", "off", "status"])
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
    parser.add_argument("--rules-state", type=Path, default=Path("/var/lib/site-network-rules"))
    parser.add_argument("--rules-status-file", type=Path, default=Path("/run/site-network-rules/status.json"))
    parser.add_argument("--rules-directory", type=Path)
    parser.add_argument("--generation", help="Apply only this pending rule generation")
    parser.add_argument("--if-due", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--curl", default="curl")
    parser.add_argument("--download-proxy")
    args = parser.parse_args()
    if args.action == "rules-status":
        try:
            print(args.rules_status_file.read_text().strip())
            return 0
        except FileNotFoundError:
            print("Rule update status is not available yet", file=sys.stderr)
            return 1
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
    rule_store = None
    phase = args.action
    consumers = (["site-dns.service", "site-dns-race-cn.service", "site-dns-race-global.service"] if args.dnsdist else []) + (["sing-box.service"] if args.sing_box else [])
    try:
        if args.action == "ipv6" and args.mode == "status":
            return ipv6.status(args.root, consumers, args.watch_underlay, args.tailscale)
        with (args.root / ".lock").open("a") as lock, ExitStack() as cleanup:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.action == "initialize":
                ipv6.initialize(args.root)
                return 0
            if args.action == "reconcile":
                ipv6.reconcile(args.root)
                return 0
            rule_store = rule_updates.Store(args.rules_state, args.rules_status_file)
            def finish_rules(exc_type, error, traceback):
                if error is not None and args.action == "update-rules":
                    rule_store.state.update(result="failure", checked=rule_updates.timestamp())
                    with recovery_step(error):
                        rule_store.save()
                rule_store.cleanup()
            cleanup.push(finish_rules)
            definitions = domain_policy.remote_rule_sets(json.loads(args.policy.read_text()), args.fragments)
            if args.action == "update-rules":
                if not definitions or (args.if_due and not rule_store.due()):
                    return 0
                rule_store.state.update(lastAttempt=time.time(), result="checking")
                rule_store.save()
                phase = "rule download"
                snapshot = rule_store.snapshot(definitions, download=True, curl=args.curl, proxy=args.download_proxy)
            elif args.action == "apply-rules":
                snapshot = rule_store.state.get("pending")
                if snapshot is None:
                    print("No pending rule update")
                    return 0
                if args.generation and args.generation != snapshot["id"]:
                    raise ValueError("The pending rules have changed; review the latest update")
            else:
                snapshot = rule_store.snapshot(definitions) if definitions else None
            args.rules_directory = rule_store.directory(snapshot) if snapshot else None
            args.ipv4_only = args.mode == "off" if args.action == "ipv6" else ipv6.ipv4_only(args.root)
            stage = Path(tempfile.mkdtemp(prefix="generation-", dir=args.root))
            if not args.prepare_command:
                raise ValueError("a sandboxed preparation command is required")
            phase = "candidate validation"
            try:
                command(args.prepare_command, str(stage), args.action, "ipv4" if args.ipv4_only else "dual",
                        str(args.rules_directory) if args.rules_directory else "", timeout=300)
            except subprocess.CalledProcessError as error:
                fd = os.open(args.root / "last-prepare.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "wb") as log:
                    log.write((error.stdout or b"") + (error.stderr or b""))
                raise ValueError("Candidate validation failed; inspect the protected last-prepare.log") from error
            finish_stage(stage, args.group)
            if args.action == "update-rules":
                pending = snapshot if snapshot != rule_store.state.get("active") else None
                rule_store.state.update(pending=pending, checked=rule_updates.timestamp(),
                                        lastSuccess=time.time(), result="pending" if pending else "unchanged")
                rule_store.save()
                print("Rule update ready for confirmation" if pending else "Rules are current")
                return 0
            phase = "policy activation"
            if args.action == "bootstrap":
                rule_store.state["active"] = snapshot
                if pending := rule_store.state.get("pending"):
                    if set(rule_updates.paths(rule_store.directory(pending))) != {
                            rule_updates.remote_source(definition) for definition in definitions}:
                        rule_store.state["pending"] = None
                rule_store.save()
                publish(args.root, stage)
            elif args.action == "ipv6":
                previous = ipv6.transition(args.root, args.ipv4_only,
                    lambda: activate(args.root, stage, False, consumers=consumers, restart_all=True),
                    lambda: ready(stage, consumers, command, wait_binding=args.watch_underlay),
                    lockdown=args.watch_underlay, tailscale=args.tailscale)
                shutil.rmtree(previous)
                return ipv6.status(args.root, consumers, args.watch_underlay, args.tailscale)
            elif args.action in {"apply", "apply-rules"}:
                previous = activate(args.root, stage, args.watch_underlay, consumers=consumers)
                saved = rule_store.state.copy()
                try:
                    rule_store.state["active"] = snapshot
                    if args.action == "apply-rules":
                        rule_store.state.update(pending=None, result="applied")
                    rule_store.save()
                except OSError as error:
                    rule_store.state = saved
                    with recovery_step(error):
                        rule_store.save()
                    with recovery_step(error):
                        activate(args.root, previous, args.watch_underlay, consumers=consumers)
                    raise
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
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.SubprocessError) as error:
        ipv6.record_failure(args.root, phase, error)
        print(f"{phase}: {ipv6.error_summary(error)}; details: {args.root / 'last-error.log'}", file=sys.stderr)
        return 1
    finally:
        if stage is not None and (args.root / "current").resolve() != stage:
            try:
                shutil.rmtree(stage)
            except OSError as error:
                print(f"Could not remove inactive policy generation: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
