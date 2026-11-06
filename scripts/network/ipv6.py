"""Coordinate the host's temporary IPv4 mode with its network policy generation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path("/run/site-network-policy")
SYSCTL = Path("/proc/sys/net/ipv6/conf")
TABLE = "site_ipv6_mode"


def error_summary(error):
    if isinstance(error, subprocess.SubprocessError):
        command = error.cmd if isinstance(error.cmd, (list, tuple)) else [error.cmd]
        label = Path(str(command[0])).name
        units = [str(arg) for arg in command[1:] if str(arg).endswith(".service")]
        if units:
            label += " " + ", ".join(units)
        if isinstance(error, subprocess.TimeoutExpired):
            return f"{label}: timed out after {error.timeout:g}s"
        return f"{label}: exit {error.returncode}"
    return str(error)


def record_failure(root, phase, error):
    """Keep command diagnostics root-only, with a concise status summary."""
    details = []
    cause = error
    while cause is not None:
        details.extend([str(cause), *getattr(cause, "__notes__", [])])
        for name in ("stdout", "stderr"):
            value = getattr(cause, name, None)
            if value:
                details.append(value.decode(errors="replace") if isinstance(value, bytes) else value)
        cause = cause.__cause__
    for name, data in (
        ("last-error.log", "\n".join(details)[-1024 * 1024:]),
        ("last-error.json", json.dumps({"time": int(time.time()), "phase": phase,
                                       "summary": error_summary(error)})),
    ):
        fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(data + "\n")


def run(*args, check=True, data=None, timeout=90):
    return subprocess.run(args, input=data, text=True, capture_output=True, check=check, timeout=timeout)


def state(root=ROOT):
    path = root / "ipv6-state.json"
    return json.loads(path.read_text()) if path.exists() else None


def ipv4_only(root=ROOT):
    current = state(root)
    return bool(current and current["ipv4_only"])


def save(root, value):
    fd, temporary = tempfile.mkstemp(prefix=".ipv6-", dir=root)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, root / "ipv6-state.json")
    finally:
        Path(temporary).unlink(missing_ok=True)


def active(unit):
    return run("systemctl", "is-active", "--quiet", unit, check=False).returncode == 0


def tunnel_state(timeout=5):
    result = run("mullvad", "status", "--json", check=False, timeout=timeout)
    # The CLI may precede JSON with an account warning for a custom peer.
    for line in reversed(result.stdout.splitlines()):
        if line.startswith("{"):
            return json.loads(line).get("state", "unknown")
    return "unavailable"


def wait_tunnel():
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if tunnel_state(timeout=min(5, max(0.01, deadline - time.monotonic()))) == "connected":
            return
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    raise RuntimeError("the local Mullvad tunnel did not become ready")


def guard(enable, *, allow_loopback=False):
    commands = []
    for family in ("inet", "bridge"):
        if run("nft", "list", "table", family, TABLE, check=False).returncode == 0:
            commands.append(f"delete table {family} {TABLE}")
        if enable:
            chains = ("input", "output", "forward") if family == "inet" else ("forward",)
            match = "meta nfproto ipv6" if family == "inet" else "ether type ip6"
            commands.append(f"table {family} {TABLE} {{")
            for chain in chains:
                loopback = ""
                if allow_loopback and family == "inet" and chain in {"input", "output"}:
                    interface = "iifname" if chain == "input" else "oifname"
                    loopback = f'{interface} "lo" ip6 saddr ::1 ip6 daddr ::1 accept; '
                commands.append(
                    f"chain {chain} {{ type filter hook {chain} priority -310; policy accept; "
                    f"{loopback}{match} counter drop; }}"
                )
            commands.append("}")
    if commands:
        run("nft", "-f", "-", data="\n".join(commands) + "\n")


def devices():
    if not active("NetworkManager.service"):
        return []
    output = run("nmcli", "-t", "-f", "DEVICE,STATE", "device", "status").stdout
    return [line.split(":", 1)[0] for line in output.splitlines() if line.split(":", 1)[-1] == "connected"]


def interfaces(only4, saved):
    if only4:
        for name in devices():
            # Device.modify changes the applied connection, leaving its profile
            # and credentials intact. Native Reapply restores that profile.
            # Some device types are externally managed (Docker/Tailscale).
            connection = run("nmcli", "-g", "GENERAL.CON-UUID", "device", "show", name).stdout.strip()
            if connection and connection != "--":
                run("nmcli", "device", "modify", name, "ipv6.method", "disabled",
                    "ipv6.addresses", "", "ipv6.gateway", "", "ipv6.routes", "", "ipv6.dns", "")
        (SYSCTL / "all/disable_ipv6").write_text("1\n")
    else:
        (SYSCTL / "all/disable_ipv6").write_text(saved.get("all", "0") + "\n")
        for path in SYSCTL.glob("*/disable_ipv6"):
            if path.parent.name == "all":
                continue
            path.write_text(saved.get(path.parent.name, saved.get("default", "0")) + "\n")
        for name in devices():
            run("nmcli", "device", "reapply", name)
        if active("systemd-networkd.service"):
            run("networkctl", "reconfigure", "*")
        elif not active("NetworkManager.service"):
            run("systemctl", "try-restart", "network-addresses-*.service")


def reconcile(root=ROOT):
    current = state(root)
    if current and current["ipv4_only"]:
        guard(True)
        interfaces(True, current["sysctl"])


def transition(root, only4, apply_policy, wait_policy, lockdown=False, tailscale=False):
    """Keep external IPv6 blocked while coordinating the transition."""
    import underlay
    current = state(root)
    if current is None:
        current = {"sysctl": {p.parent.name: p.read_text().strip() for p in SYSCTL.glob("*/disable_ipv6")}}
    current.update(ipv4_only=only4, phase="applying")
    current.pop("failed_step", None)
    guard(True, allow_loopback=not only4)
    save(root, current)
    watching = lockdown and active("site-network-underlay.service")
    tail_active = tailscale and active("tailscaled.service")
    step = "stopping network services"
    try:
        if watching:
            run("systemctl", "stop", "site-network-underlay.service")
        if lockdown:
            run("systemctl", "stop", "site-network-connect.service", "sing-box.service")
            run("mullvad", "lockdown-mode", "set", "on")
            run("mullvad", "disconnect")
        if tail_active:
            run("systemctl", "stop", "tailscaled.service")
        step = "applying interface settings"
        interfaces(only4, current["sysctl"])
        if lockdown:
            underlay.save(Path("/run/site-network-underlay/underlay.json"), underlay.observe(only4))
            run("systemctl", "restart", "site-network-routing.service")
        step = "activating DNS and proxy configuration"
        previous = apply_policy()
        step = "starting the local tunnel and Tailscale"
        if lockdown:
            run("systemctl", "restart", "site-network-connect.service")
        if tail_active:
            run("systemctl", "start", "tailscaled.service")
        if active("systemd-resolved.service"):
            run("resolvectl", "flush-caches")
        if only4:
            interfaces(True, current["sysctl"])
        else:
            guard(False)
        step = "waiting for physical bindings and network services"
        if watching:
            run("systemctl", "start", "site-network-underlay.service")
        wait_policy()
        if lockdown:
            wait_tunnel()
        if only4:
            current["phase"] = "ready"
            save(root, current)
        else:
            (root / "ipv6-state.json").unlink()
        return previous
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        try:
            guard(True)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as recovery:
            error.add_note("Restoring IPv6 guard: " + error_summary(recovery))
        current.update(ipv4_only=True, phase="incomplete", failed_step=step)
        save(root, current)
        raise RuntimeError(
            f"IPv6 transition incomplete after {step}: {error_summary(error)}; "
            "inspect network-ipv6 status, then retry off or restore"
        ) from error
    finally:
        primary = sys.exception()
        for unit, enabled in (("site-network-underlay.service", watching), ("tailscaled.service", tail_active)):
            if enabled:
                try:
                    run("systemctl", "start", unit)
                except (OSError, subprocess.SubprocessError) as cleanup:
                    if primary is None:
                        raise
                    primary.add_note("Restarting observer: " + error_summary(cleanup))


def status(root, consumers, lockdown=False, tailscale=False):
    current = state(root)
    only4 = bool(current and current["ipv4_only"])
    print("Requested: " + ("IPv4 only" if only4 else "normal (IPv4 preferred)"))
    print("Transition: " + (current["phase"] if current else "ready"))
    if current and "failed_step" in current:
        print("Failed step: " + current["failed_step"])
    failure = root / "last-error.json"
    if failure.exists():
        last = json.loads(failure.read_text())
        print(f"Last failure ({last['time']}): {last['phase']}: {last['summary']}")
        print("Protected details: " + str(root / "last-error.log"))
    values = {p.parent.name: p.read_text().strip() for p in SYSCTL.glob("*/disable_ipv6")}
    enabled = sorted(name for name, value in values.items() if name not in {"all", "default"} and value != "1")
    print("IPv6-enabled interfaces: " + (", ".join(enabled) or "none"))
    tables = [run("nft", "list", "table", family, TABLE, check=False).returncode == 0 for family in ("inet", "bridge")]
    blocked = all(tables)
    print("IPv6 packet guard: " + ("active" if blocked else "partial" if any(tables) else "inactive"))
    for unit in consumers:
        print(f"{unit}: " + run("systemctl", "show", "-p", "ActiveState", "--value", unit).stdout.strip())
    applied = root / "current/ipv6-mode.json"
    actual = json.loads(applied.read_text())["ipv4_only"] if applied.exists() else None
    print("DNS/proxy generation: " + ("IPv4 only" if actual else "normal" if actual is False else "unavailable"))
    complete = actual == only4 and all(active(unit) for unit in consumers)
    if lockdown:
        tunnel = tunnel_state()
        print("Mullvad tunnel: " + tunnel)
        complete &= tunnel == "connected"
    if tailscale:
        print("Tailscale service: " + ("active" if active("tailscaled.service") else "inactive"))
    if only4:
        complete &= blocked and not enabled and values.get("default") == "1" and current["phase"] == "ready"
    else:
        complete &= not any(tables)
    return 0 if complete else 1
