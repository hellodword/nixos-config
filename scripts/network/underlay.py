#!/usr/bin/env python3
"""Follow physical default routes without ever selecting a VPN interface.

On an address/interface change, stop the excluded proxy before replacing its
binding. Mullvad Lockdown remains independent of this watcher and the proxy.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import tempfile
import time
import ipv6


def select(routes, links, addresses, physical):
    usable = {link["ifname"] for link in links if "UP" in link.get("flags", [])
              and link["ifname"] in physical and link.get("operstate") in ("UP", "UNKNOWN")}
    eligible = [route for route in routes if route.get("dst") == "default"
                and route.get("dev") in usable and route.get("type", "unicast") == "unicast"]
    if not eligible:
        return None
    route = min(eligible, key=lambda r: (r.get("metric", 0), r["dev"]))
    iface = route["dev"]
    selected = {"interface": iface, "gateway": route.get("gateway")}
    for entry in addresses:
        if entry["ifname"] != iface:
            continue
        for address in entry.get("addr_info", []):
            if address.get("scope") != "global" or address.get("tentative") or address.get("deprecated"):
                continue
            value = ipaddress.ip_address(address["local"])
            if value.is_loopback or value.is_link_local:
                continue
            field = "ipv4" if value.version == 4 else "ipv6"
            # Prefer a stable address to avoid restarting for each privacy address.
            if field not in selected or not address.get("temporary"):
                selected[field] = str(value)
    return selected if "ipv4" in selected or "ipv6" in selected else None


def observe(ipv4_only=None, timeout=10):
    ipv4_only = ipv6.ipv4_only() if ipv4_only is None else ipv4_only
    deadline = time.monotonic() + timeout
    def ip(*args):
        return json.loads(subprocess.run(["ip", "-j", *args], check=True, capture_output=True,
                                         text=True, timeout=max(0.001, deadline - time.monotonic())).stdout)
    links = ip("link", "show")
    physical = {link["ifname"] for link in links if (Path("/sys/class/net") / link["ifname"] / "device").exists()}
    # Mullvad policy tables are deliberately not candidates. Prefer an IPv4
    # default when present, otherwise use the IPv6 physical default.
    routes4, routes6 = ip("-4", "route", "show", "table", "main"), ip("-6", "route", "show", "table", "main")
    addresses = ip("address", "show")
    selected = select(routes4, links, addresses, physical)
    if ipv4_only:
        if selected:
            selected.pop("ipv6", None)
        return selected if selected and "ipv4" in selected else None
    return selected or select(routes6, links, addresses, physical)


def save(path, state):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".underlay-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def notify_ready():
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
        channel.connect("\0" + address[1:] if address.startswith("@") else address)
        channel.sendall(b"READY=1")


def safe_observe(ipv4_only=None):
    try:
        return observe(ipv4_only=ipv4_only)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def stop_proxy():
    stopped = subprocess.run(["systemctl", "stop", "sing-box.service"], timeout=40, check=False)
    if stopped.returncode:
        raise SystemExit("cannot stop proxy for an underlay change")


def start_proxy():
    subprocess.run(["systemctl", "--no-block", "start", "sing-box.service"], check=True, timeout=10)


def drain_events(selector, stream, debounce=0.15, max_wait=0.5):
    started = time.monotonic()
    quiet_until = started + debounce
    max_deadline = started + max_wait
    while True:
        now = time.monotonic()
        timeout = min(quiet_until, max_deadline) - now
        if timeout <= 0:
            return True
        if not selector.select(timeout=timeout):
            return True
        chunk = os.read(stream.fileno(), 65536)
        if not chunk:
            return False
        quiet_until = min(time.monotonic() + debounce, max_deadline)


def watch(output_path, spawn_monitor=None):
    if spawn_monitor is None:
        def spawn_monitor():
            return subprocess.Popen(
                ["ip", "monitor", "link", "address", "route"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )

    had_output = output_path.exists()
    try:
        previous = json.loads(output_path.read_text())
    except (OSError, ValueError):
        previous = object()

    current = safe_observe()
    if current != previous:
        if had_output:
            stop_proxy()
        save(output_path, current)
        notify_ready()
        if current is not None:
            start_proxy()
        previous = current
    else:
        notify_ready()
        if current is not None:
            start_proxy()

    def apply_current():
        nonlocal previous
        latest = safe_observe()
        if latest != previous:
            stop_proxy()
            save(output_path, latest)
            if latest is not None:
                start_proxy()
            previous = latest

    running = True

    def handle_stop(_signum, _frame):
        nonlocal running
        running = False

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, handle_stop)

    while running:
        monitor = spawn_monitor()
        try:
            apply_current()
            with selectors.DefaultSelector() as selector:
                selector.register(monitor.stdout, selectors.EVENT_READ)
                while running:
                    if not selector.select(timeout=1.0):
                        if monitor.poll() is not None:
                            break
                        continue
                    chunk = os.read(monitor.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    alive = drain_events(selector, monitor.stdout)
                    apply_current()
                    if not alive:
                        break
        finally:
            if monitor.poll() is None:
                monitor.terminate()
                try:
                    monitor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    monitor.kill()
                    monitor.wait()
            if monitor.stdout is not None:
                monitor.stdout.close()
        if running:
            time.sleep(0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/run/site-network-underlay/underlay.json"))
    args = parser.parse_args()
    watch(args.output)


if __name__ == "__main__":
    main()
