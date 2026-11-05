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


def observe(ipv4_only=None):
    ipv4_only = ipv6.ipv4_only() if ipv4_only is None else ipv4_only
    def ip(*args):
        return json.loads(subprocess.run(["ip", "-j", *args], check=True, capture_output=True,
                                         text=True, timeout=10).stdout)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/run/site-network-underlay/underlay.json"))
    args = parser.parse_args()
    try:
        previous = json.loads(args.output.read_text())
    except (OSError, ValueError):
        previous = object()
    first = True
    while True:
        try:
            # The local WireGuard receiver must run before Mullvad can connect.
            current = observe()
        except (OSError, ValueError, subprocess.SubprocessError):
            current = None
        if current != previous:
            # A completed stop is required before any binding changes. Failure
            # leaves the old known configuration; it never clears protection.
            stopped = subprocess.run(["systemctl", "stop", "sing-box.service"], timeout=40, check=False)
            if stopped.returncode:
                raise SystemExit("cannot stop proxy for an underlay change")
            save(args.output, current)
            if current is not None:
                subprocess.run(["systemctl", "--no-block", "start", "sing-box.service"], check=True, timeout=10)
            previous = current
        elif first and current is not None:
            # A coordinated policy update already started the proxy with this
            # binding. Starting an active unit is a no-op; do not stop it again.
            # This also recovers an observer interrupted after stopping the proxy.
            subprocess.run(["systemctl", "--no-block", "start", "sing-box.service"], check=True, timeout=10)
        first = False
        time.sleep(2)


if __name__ == "__main__":
    main()
