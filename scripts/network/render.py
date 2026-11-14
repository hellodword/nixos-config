#!/usr/bin/env python3
"""Combine public policy with runtime proxy credentials, validate, then replace.

No configuration or validator output is printed. Source credentials are never
passed in argv or environment. Failed validation preserves the existing output.
"""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile

from domain_policy import read_json


def combine(template, provider, wireguard_key=None, wireguard_peer=None):
    result = copy.deepcopy(template)
    purposes = result.pop("_purposeGroups", [])
    if not isinstance(provider, dict) or set(provider) - {"outbounds", "endpoints", "exits", "groups"}:
        raise ValueError("provider contains native outbounds and optional endpoints arrays")
    nodes = provider.get("outbounds", [])
    endpoints = provider.get("endpoints", [])
    if not isinstance(nodes, list) or not isinstance(endpoints, list) or not nodes + endpoints:
        raise ValueError("provide at least one concrete outbound or endpoint")
    known = {o["tag"] for o in result["outbounds"] + result.get("endpoints", [])}
    tags = []
    for node in nodes + endpoints:
        tag = node.get("tag") if isinstance(node, dict) else None
        if not isinstance(tag, str) or not tag or tag in known:
            raise ValueError("proxy tags must be nonempty and unique across outbounds and endpoints")
        if node.get("type") in {None, "direct", "block", "dns", "selector", "urltest"}:
            raise ValueError("provider must contain concrete proxy outbounds or endpoints")
        known.add(tag)
        tags.append(tag)
    if "groups" in provider:
        generated = grouped_outbounds(provider, known - {"auto", "proxy"}, selected_only=True)
        result["outbounds"] = [node for node in result["outbounds"] if node["tag"] not in {"auto", "proxy"}]
        result["outbounds"].extend(generated)
    else:
        for outbound in result["outbounds"]:
            if outbound["tag"] == "auto":
                outbound["outbounds"] = tags
            elif outbound["tag"] == "proxy":
                outbound["outbounds"] = ["auto", *tags]
    for purpose in purposes:
        if purpose not in provider.get("groups", {}):
            if purpose in known:
                raise ValueError("provider node conflicts with a declared purpose")
            result["outbounds"].append({"type": "selector", "tag": purpose,
                                       "outbounds": ["proxy"], "default": "proxy"})
    result["outbounds"].extend(copy.deepcopy(nodes))
    result.setdefault("endpoints", []).extend(copy.deepcopy(endpoints))
    for endpoint in result.get("endpoints", []):
        if endpoint.get("tag") == "transparent":
            if not wireguard_key or not wireguard_peer:
                raise ValueError("local WireGuard peer credentials are missing")
            endpoint["private_key"] = wireguard_key.strip()
            endpoint["peers"][0]["public_key"] = wireguard_peer.strip()
    return result


def grouped_outbounds(provider, known=(), *, selected_only=False):
    """Select a logical exit, then either probe or pin its complete paths."""
    known = set(known)
    paths = {node["tag"] for node in provider.get("outbounds", []) + provider.get("endpoints", [])}
    exits = provider["exits"]
    generated = []
    for name, exit_ in exits.items():
        tag = "exit-" + name
        if {tag, tag + "-auto"} & known or not exit_["paths"] or not set(exit_["paths"]) <= paths:
            raise ValueError("exit paths must reference concrete provider nodes")
        known.update((tag, tag + "-auto"))
        generated.append({"type": "urltest", "tag": tag + "-auto", "outbounds": exit_["paths"],
                          "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 100,
                          "interrupt_exist_connections": False})
        generated.append({"type": "selector", "tag": tag, "default": tag + "-auto",
                          "outbounds": [tag + "-auto", *exit_["paths"]], "interrupt_exist_connections": False})
    for name, group in provider["groups"].items():
        if name in known or name in {"direct", "private", "tailnet", "local", "auto", "transparent"}:
            raise ValueError("purpose group conflicts with another outbound")
        if not group["exits"] or not set(group["exits"]) <= exits.keys() or group["default"] not in group["exits"]:
            raise ValueError("purpose group requires an explicit available default exit")
        known.add(name)
        choices = [group["default"]] if selected_only else group["exits"]
        generated.append({"type": "selector", "tag": name,
                          "outbounds": ["exit-" + value for value in choices],
                          "default": "exit-" + group["default"]})
    if "proxy" not in provider["groups"]:
        raise ValueError("grouped providers require a proxy purpose")
    return generated


def address_family(config):
    """Apply the current mode after provider composition and physical binding."""
    only4 = config.pop("_ipv4Only", False)
    resolver = config["route"].get("default_domain_resolver", "dns-policy")
    resolver = {"server": resolver} if isinstance(resolver, str) else dict(resolver)
    resolver.setdefault("strategy", "prefer_ipv4")
    if only4:
        resolver["strategy"] = "ipv4_only"
        config["dns"]["strategy"] = "ipv4_only"
    config["route"]["default_domain_resolver"] = resolver
    for node in config["outbounds"] + config.get("endpoints", []):
        if node.get("type") in {"selector", "urltest"} or node.get("tag") in {"local", "transparent"}:
            continue
        default = resolver
        if node.get("tag") not in {"direct", "private", "tailnet"} and any(
                server["tag"] == "dns-bootstrap" for server in config["dns"]["servers"]):
            default = resolver | {"server": "dns-bootstrap"}
        value = node.get("domain_resolver", default)
        value = {"server": value} if isinstance(value, str) else dict(value)
        value.setdefault("strategy", "prefer_ipv4")
        if only4:
            value["strategy"] = "ipv4_only"
            node.pop("inet6_bind_address", None)
            # A literal IPv6 peer cannot be reached through another proxy while
            # IPv4-only is active. Its ordinary IPv6 socket remains unavailable.
            addresses = [node.get("server", "")] + [peer.get("address", "") for peer in node.get("peers", [])]
            if any(is_ipv6(address) for address in addresses):
                node.pop("detour", None)
        node["domain_resolver"] = value
    if only4:
        for node in config.get("endpoints", []):
            if node.get("type") in {"wireguard", "openvpn-client"}:
                if "address" in node:
                    node["address"] = [address for address in node["address"] if ":" not in address]
                for peer in node.get("peers", []):
                    peer["allowed_ips"] = [address for address in peer["allowed_ips"] if ":" not in address]
            if node.get("type") == "openvpn-client":
                node["block_ipv6"] = True
                node.pop("peer_address_ipv6", None)
                node["routes"] = [prefix for prefix in node.get("routes", []) if ":" not in prefix]
                node["pull_filters"] = [
                    {"action": "ignore", "text": "ifconfig-ipv6"},
                    {"action": "ignore", "text": "route-ipv6"},
                    *node.get("pull_filters", []),
                ]
        rules = config["route"]["rules"]
        # FakeIP resolves after sniff and DNS hijacking, before policy routing.
        # Other modes resolve here so proxy protocols receive IPv4 destinations.
        fakeip = any(server["type"] == "fakeip" for server in config["dns"]["servers"])
        resolve = [] if fakeip else [
            {"action": "resolve", "strategy": "ipv4_only"}]
        config["route"]["rules"] = [
            {"ip_version": 6, "action": "reject", "method": "default"},
            *resolve,
            *rules,
        ]
        for rule in rules:
            if is_ipv6(rule.get("override_address", "")):
                raise ValueError("an IPv6 destination override needs an IPv4 alternative")
            if rule.get("action") == "resolve":
                rule["strategy"] = "ipv4_only"
    return config


def is_ipv6(address):
    try:
        return ipaddress.ip_address(address).version == 6
    except ValueError:
        return False


def bind_underlay(config, underlay):
    if not isinstance(underlay, dict) or not underlay.get("interface"):
        raise ValueError("no physical underlay; proxy remains stopped")
    interface = underlay["interface"]
    if not isinstance(interface, str) or not interface or len(interface) > 15 or "/" in interface:
        raise ValueError("invalid physical interface")
    import ipaddress
    # The socket's initial route lookup precedes nftables' cgroup marking.
    # Use the same locked Mullvad mark before that lookup as well.
    bind = {"bind_interface": interface, "routing_mark": 0x6D6F6C65}
    for version, key in ((4, "ipv4"), (6, "ipv6")):
        if key in underlay:
            address = ipaddress.ip_address(underlay[key])
            if address.version != version or address.is_loopback or address.is_link_local:
                raise ValueError("invalid underlay address")
            bind[f"inet{version}_bind_address"] = str(address)
    if not any(key in bind for key in ("inet4_bind_address", "inet6_bind_address")):
        raise ValueError("underlay has no usable address")
    for outbound in config["outbounds"] + config.get("endpoints", []):
        if outbound.get("type") in {"selector", "urltest"} or outbound["tag"] in {"local", "tailnet", "transparent"}:
            continue
        if "netns" in outbound or outbound.get("detour") in {"local", "direct"}:
            raise ValueError("provider cannot bypass declared physical bindings")
        outbound.update(bind)
        if outbound["tag"] not in {"direct", "private"}:
            resolver = outbound.get("domain_resolver", {})
            resolver = {} if isinstance(resolver, str) else dict(resolver)
            outbound["domain_resolver"] = resolver | {"server": "dns-bootstrap"}
    return config


def render(template, provider, destination, checker, wireguard_key=None, underlay=None, wireguard_peer=None, clash_secret=None):
    data = combine(json.loads(template.read_text()), read_json(provider),
                   wireguard_key.read_text() if wireguard_key else None,
                   wireguard_peer.read_text() if wireguard_peer else None)
    if clash_secret is not None:
        secret = clash_secret.read_text().strip()
        if not secret:
            raise ValueError("Clash API token must not be empty")
        data["experimental"]["clash_api"]["secret"] = secret
    if underlay is not None:
        data = bind_underlay(data, json.loads(underlay.read_text()))
    data = address_family(data)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError("refusing a symlink configuration destination")
    fd, temp = tempfile.mkstemp(prefix=".validated-", suffix=".json", dir=destination.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, ensure_ascii=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        checked = subprocess.run([checker, "check", "-c", temp], capture_output=True, timeout=30)
        if checked.returncode:
            # The config may contain personal endpoint names. Do not send diagnostic text to journald.
            raise ValueError("sing-box rejected the configuration; previous configuration retained")
        os.replace(temp, destination)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--provider", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--checker", required=True)
    parser.add_argument("--wireguard-key", type=Path)
    parser.add_argument("--underlay", type=Path)
    parser.add_argument("--wireguard-peer", type=Path)
    parser.add_argument("--clash-secret", type=Path)
    args = parser.parse_args()
    try:
        render(args.template, args.provider, args.output, args.checker, args.wireguard_key, args.underlay, args.wireguard_peer, args.clash_secret)
    except (OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, "network configuration rejected; check schema and runtime credentials locally\n")


if __name__ == "__main__":
    main()
