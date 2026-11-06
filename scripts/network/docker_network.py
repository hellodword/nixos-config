"""Keep Docker's local bridges reachable while Internet traffic follows host policy."""
import argparse
import http.client
import ipaddress
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys

import ipv6

TABLE = "site_containers"
ROUTE_TABLE = "64500"
PRIORITY = "94"
PROTOCOL = "99"
NEIGHBOR_COMMENT = "site-container-neighbors"


def run(*args, check=True, data=None):
    return subprocess.run(args, input=data, text=True, capture_output=True, check=check, timeout=10)


class Docker(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect("/run/docker.sock")


def topology():
    connection = Docker("localhost", timeout=10)
    try:
        connection.request("GET", "/networks")
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Docker network inventory: HTTP {response.status}")
        networks = json.load(response)
    finally:
        connection.close()
    bridges = set()
    gateways = set()
    only4 = ipv6.ipv4_only()
    reconcile = False
    addresses = {link["ifname"]: {str(ipaddress.ip_interface(f"{a['local']}/{a['prefixlen']}"))
                               for a in link["addr_info"] if a["family"] == "inet6"}
                 for link in json.loads(run("ip", "-j", "address", "show").stdout)}
    for network in networks:
        if network["Driver"] != "bridge" or (network.get("Labels") or {}).get("org.nixos-config.service"):
            continue
        name = (network.get("Options") or {}).get("com.docker.network.bridge.name")
        name = name or ("docker0" if network["Name"] == "bridge" else "br-" + network["Id"][:12])
        bridges.add(name)
        if network["Name"] == "bridge":
            for ipam in network.get("IPAM", {}).get("Config") or []:
                if gateway := ipam.get("Gateway"):
                    gateways.add((name, str(ipaddress.ip_address(gateway))))
        # Disabling IPv6 removes bridge addresses in the host namespace.
        # Docker retains its IPAM configuration and the containers' addresses;
        # restore its gateway when the host enables IPv6 again.
        disabled = Path("/proc/sys/net/ipv6/conf") / name / "disable_ipv6"
        if name in addresses and disabled.read_text().strip() == "0":
            if only4:
                reconcile = True
                continue
            for ipam in network.get("IPAM", {}).get("Config") or []:
                gateway = ipam.get("Gateway")
                if gateway and ipaddress.ip_address(gateway).version == 6:
                    prefix = ipaddress.ip_network(ipam["Subnet"]).prefixlen
                    address = str(ipaddress.ip_interface(f"{gateway}/{prefix}"))
                    if address not in addresses[name]:
                        run("ip", "-6", "address", "replace", address, "dev", name)
    if reconcile:
        # Docker may enable IPv6 explicitly while creating a bridge. The mode
        # coordinator owns host sysctls and serializes changes with on/off.
        run("systemctl", "--no-block", "start", "site-network-ipv6-reconcile.service")
    routes = {}
    for family in ("-4", "-6"):
        for route in json.loads(run("ip", family, "-j", "route", "show", "table", "main").stdout):
            if route.get("dev") not in bridges or route.get("dst", "default") == "default" or route.get("gateway"):
                continue
            network = ipaddress.ip_network(route["dst"])
            if network.is_link_local or network.is_multicast:
                continue
            routes[family, str(network)] = (route["dev"], route.get("prefsrc"))
    return sorted(bridges), routes, sorted(gateways)


def rules(action):
    for family in ("-4", "-6"):
        current = json.loads(run("ip", family, "-N", "-j", "rule", "show").stdout)
        owned = any(str(r.get("table")) == ROUTE_TABLE and str(r.get("protocol")) == PROTOCOL
                    and str(r.get("priority")) == PRIORITY for r in current)
        if (action == "add" and not owned) or (action == "del" and owned):
            run("ip", family, "rule", action, "pref", PRIORITY, "table", ROUTE_TABLE, "protocol", PROTOCOL)


def routing(desired):
    for family in ("-4", "-6"):
        existing = run("ip", family, "-j", "route", "show", "table", ROUTE_TABLE, check=False)
        current = {r["dst"]: r for r in json.loads(existing.stdout or "[]")}
        for (version, prefix), (device, source) in desired.items():
            if version != family:
                continue
            old = current.pop(prefix, {})
            if old.get("dev") != device or old.get("prefsrc") != source:
                run("ip", family, "route", "replace", "table", ROUTE_TABLE, prefix,
                    "dev", device, "proto", PROTOCOL, *(["src", source] if source else []))
        for prefix in current:
            run("ip", family, "route", "del", "table", ROUTE_TABLE, prefix, "proto", PROTOCOL)


def firewall(bridges, routes, gateways, lockdown, host_ports):
    interfaces = ", ".join(json.dumps(name) for name in bridges)
    local_output = []
    host_input = []
    for interface, gateway in gateways:
        family = "ip" if ipaddress.ip_address(gateway).version == 4 else "ip6"
        for protocol, ports in host_ports.items():
            if ports:
                port_set = ", ".join(str(port) for port in sorted(set(ports)))
                host_input.append(f'iifname {json.dumps(interface)} {family} daddr {gateway} '
                                  f'{protocol} dport {{ {port_set} }} ct mark set 0xf41 meta mark set 0x646f636b')
    if lockdown:
        # OUTPUT retains the original interface after Docker's DNAT. Match the
        # translated destination against the bridge routes we actually own.
        for family, protocol in (("-4", "ip"), ("-6", "ip6")):
            prefixes = sorted(prefix for version, prefix in routes if version == family)
            if prefixes:
                local_output.append(f"{protocol} daddr {{ {', '.join(prefixes)} }} "
                                    "ct mark set 0xf41 meta mark set 0x6d6f6c65")
    contents = f"""table inet {TABLE} {{
    set bridges {{ type ifname; {('elements = { ' + interfaces + ' };') if bridges else ''} }}
    chain input {{
        type filter hook input priority -15; policy accept;
        {chr(10).join(host_input)}
    }}
    chain output {{
        type route hook output priority -90; policy accept;
        {chr(10).join(local_output)}
    }}
    chain forward {{
        type filter hook forward priority -15; policy accept;
        {('iifname @bridges oifname @bridges ct mark set 0xf41') if lockdown else ''}
    }}
}}
"""
    exists = run("nft", "list", "table", "inet", TABLE, check=False).returncode == 0
    run("nft", "-f", "-", data=(f"delete table inet {TABLE}\n" if exists else "") + contents)


def dns_clients(bridges):
    # nftables reload recreates declared sets. Compare their actual contents,
    # so the ordinary Docker networks are restored without replacing DNS rules.
    result = run("nft", "-j", "list", "set", "inet", "site_dns", "docker_bridges", check=False)
    if result.returncode:
        return
    current = next(item["set"].get("elem", []) for item in json.loads(result.stdout)["nftables"] if "set" in item)
    if sorted(current) != bridges:
        commands = "flush set inet site_dns docker_bridges\n"
        if bridges:
            commands += "add element inet site_dns docker_bridges { " + ", ".join(json.dumps(name) for name in bridges) + " }\n"
        run("nft", "-f", "-", data=commands)


def neighbor_rules():
    result = run("nft", "-a", "-j", "list", "table", "inet", "mullvad", check=False)
    if result.returncode:
        return None
    return sorted((rule["chain"], rule["handle"])
                  for item in json.loads(result.stdout)["nftables"]
                  if (rule := item.get("rule", {})).get("comment") == NEIGHBOR_COMMENT)


def neighbors(bridges, previous):
    # NDP is untracked, so connection marks cannot allow it through Mullvad.
    # Docker uses subnet gateways as well as link-local neighbors. Keep only
    # their link-scoped solicitation/advertisement rules in the active table.
    owned = neighbor_rules()
    if owned is None:
        return None
    current = (tuple(bridges), tuple(owned))
    if current == previous and len(owned) == (3 if bridges else 0):
        return current
    commands = [f"delete rule inet mullvad {chain} handle {handle}" for chain, handle in owned]
    if bridges:
        interfaces = ", ".join(json.dumps(name) for name in bridges)
        incoming, outgoing = f"iifname {{ {interfaces} }}", f"oifname {{ {interfaces} }}"
        for chain, direction in (("input", incoming), ("output", outgoing),
                                 ("forward", incoming + " " + outgoing)):
            commands.append(f'insert rule inet mullvad {chain} {direction} '
                            'ip6 hoplimit 255 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } '
                            f'icmpv6 code 0 counter accept comment "{NEIGHBOR_COMMENT}"')
    if commands:
        run("nft", "-f", "-", data="\n".join(commands) + "\n")
    return tuple(bridges), tuple(neighbor_rules() or [])


def notify():
    address = os.environ.get("NOTIFY_SOCKET")
    if address:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
            channel.connect("\0" + address[1:] if address.startswith("@") else address)
            channel.sendall(b"READY=1")


def watch(dns, lockdown, host_ports):
    # Subscribe before the initial inventory. Periodic reconciliation also
    # observes address-family changes and an administrator's firewall reload.
    commands = [("docker", "events", "--filter", "type=network", "--format", "{{json .}}"),
                ("ip", "monitor", "link", "address", "route")]
    if lockdown:
        commands.append(("nft", "monitor", "ruleset"))
    processes = []
    try:
        with selectors.DefaultSelector() as selector:
            for command in commands:
                process = subprocess.Popen(command, stdout=subprocess.PIPE)
                processes.append(process)
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
            previous = None
            previous_neighbors = None
            rules("add")
            while True:
                bridges, routes, gateways = topology()
                routing(routes)
                current = (bridges, routes, gateways)
                if current != previous or run("nft", "list", "table", "inet", TABLE, check=False).returncode:
                    firewall(bridges, routes, gateways, lockdown, host_ports)
                    print(f"Docker local routing: {len(bridges)} bridges, {len(routes)} routes", flush=True)
                    previous = current
                if dns:
                    dns_clients(bridges)
                if lockdown:
                    previous_neighbors = neighbors(bridges, previous_neighbors)
                notify()
                for key, _ in selector.select(timeout=10):
                    if not os.read(key.fileobj.fileno(), 65536):
                        raise RuntimeError("network event stream ended")
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)


def stop():
    dns_clients([])
    neighbors([], None)
    rules("del")
    for family in ("-4", "-6"):
        run("ip", family, "route", "flush", "table", ROUTE_TABLE, "proto", PROTOCOL)
    if run("nft", "list", "table", "inet", TABLE, check=False).returncode == 0:
        run("nft", "delete", "table", "inet", TABLE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "stop"])
    parser.add_argument("--dns", action="store_true")
    parser.add_argument("--lockdown", action="store_true")
    parser.add_argument("--host-tcp-port", action="append", type=int, default=[])
    parser.add_argument("--host-udp-port", action="append", type=int, default=[])
    args = parser.parse_args()
    try:
        watch(args.dns, args.lockdown, {"tcp": args.host_tcp_port, "udp": args.host_udp_port}) if args.action == "run" else stop()
    except (OSError, ValueError, RuntimeError, http.client.HTTPException, subprocess.SubprocessError) as error:
        print(f"Docker local networking: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
