"""Inventory relationships and native proxy configurations.

The deployment inventory is private. Only metadata() is evaluated by Nix;
rendered credentials are written to the deployment context outside the store.
"""
import copy
import hashlib
import hmac
import ipaddress
import json
import re
from pathlib import Path
from urllib.parse import urlparse

UDP_FIRST, UDP_LAST = 20000, 29999
DEFAULT_DNS = json.loads((Path(__file__).resolve().parents[2] / "data/network/vps-dns.json").read_text())


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", value):
        raise ValueError("identifiers use lowercase letters, digits and hyphens")
    return value


def secret_values(value, secrets):
    if isinstance(value, dict):
        if set(value) == {"secret"}:
            return copy.deepcopy(secrets[value["secret"]])
        return {key: secret_values(item, secrets) for key, item in value.items()}
    if isinstance(value, list):
        return [secret_values(item, secrets) for item in value]
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Inventory:
    def __init__(self, document):
        self.data = copy.deepcopy(document)
        self.nodes = self.data["nodes"]
        self.exits = self.data["exits"]
        self.subscriptions = self.data.get("subscriptions", {})
        self.secrets = self.data.get("secrets", {})
        slots, snis = set(), set()
        for name, node in self.nodes.items():
            identifier(name)
            ipaddress.IPv4Address(node["address"])
            slot = node["udpSlot"]
            if type(slot) is not int or slot < 0 or UDP_FIRST + slot > UDP_LAST or slot in slots:
                raise ValueError(f"each node requires a unique udpSlot between 0 and {UDP_LAST - UDP_FIRST}")
            slots.add(slot)
            sni = node["serverName"]
            if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", sni) or sni in snis:
                raise ValueError("nodes require unique DNS serverName values")
            snis.add(sni)
            ssh_host = node["sshHost"]
            if not isinstance(ssh_host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", ssh_host):
                raise ValueError("nodes require a concrete SSH host alias")
            if not node["sshServer"].get("rootAuthorizedKeys"):
                raise ValueError("nodes require sshServer.rootAuthorizedKeys")
            if not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,15}", node.get("interface", "eth0")):
                raise ValueError("invalid uplink interface name")
            for path in node.get("modules", []):
                if not re.fullmatch(r"[a-zA-Z0-9_/-]+\.nix", path) or path.startswith("/") or ".." in path.split("/"):
                    raise ValueError("node modules must be repository-relative Nix paths")
            for hostname, upstream in node.get("web", {}).items():
                if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", hostname) or hostname == sni:
                    raise ValueError("web names must differ from the node proxy SNI")
                url = urlparse(upstream)
                if url.scheme not in {"http", "https"} or url.hostname not in {"127.0.0.1", "::1", "localhost"}:
                    raise ValueError("web upstreams must be local HTTP services")
        for name, exit_ in self.exits.items():
            identifier(name)
            carriers = exit_["nodes"]
            if not carriers or len(set(carriers)) != len(carriers) or not set(carriers) <= self.nodes.keys():
                raise ValueError("exit nodes must name distinct existing nodes")
            if exit_["type"] not in {"native", "wireguard", "socks", "openvpn-client"}:
                raise ValueError("unsupported exit type")
            if exit_["type"] == "native" and len(carriers) != 1:
                raise ValueError("a native exit belongs to one node")
        keys, paths = set(), set()
        for name, subscription in self.subscriptions.items():
            identifier(name)
            path = subscription["path"]
            if not re.fullmatch(r"/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", path) or path in paths:
                raise ValueError("subscriptions require distinct /UUIDv4 paths")
            paths.add(path)
            key = subscription["key"]
            if not isinstance(key, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", key):
                raise ValueError("subscription keys require 32 bytes encoded as hexadecimal")
            key = bytes.fromhex(key)
            if key in keys:
                raise ValueError("each subscription requires an independent key")
            keys.add(key)
            exits = subscription["exits"]
            if not isinstance(exits, list) or not exits or not set(exits) <= self.exits.keys():
                raise ValueError("subscriptions must authorize existing exits")
            if len(set(exits)) != len(exits):
                raise ValueError("subscription exits must be distinct")
            for group, binding in subscription["groups"].items():
                identifier(group)
                if group in {"direct", "private", "tailnet", "local", "auto", "transparent", "cn", "global"}:
                    raise ValueError("purpose group conflicts with a local route")
                if "default" not in binding:
                    if len(binding["exits"]) != 1:
                        raise ValueError("groups with multiple exits require an explicit default")
                    binding["default"] = binding["exits"][0]
                if binding["default"] not in binding["exits"] or not set(binding["exits"]) <= set(exits):
                    raise ValueError("groups must select authorized exits")
            if "proxy" not in subscription["groups"]:
                raise ValueError("subscriptions require a proxy group")

    def port(self, node):
        return UDP_FIRST + self.nodes[node]["udpSlot"]

    def password(self, subscription_id, exit_id, protocol):
        key = bytes.fromhex(self.subscriptions[subscription_id]["key"])
        message = f"vps-proxy/{exit_id}/{protocol}".encode("utf-8")
        return hmac.new(key, message, hashlib.sha256).hexdigest()

    def credentials(self, node, protocol):
        return [
            {"name": f"{subscription_id}/{exit_id}/{protocol}",
             "password": self.password(subscription_id, exit_id, protocol)}
            for subscription_id, subscription in self.subscriptions.items()
            for exit_id in subscription["exits"]
            if node in self.exits[exit_id]["nodes"]
        ]

    def server(self, node):
        tls = {
            "enabled": True,
            "certificate_path": "/run/credentials/site-vps-proxy.service/tls.crt",
            "key_path": "/run/credentials/site-vps-proxy.service/tls.key",
        }
        outbounds = [{"type": "direct", "tag": "bootstrap"}]
        endpoints, dns, rules, dns_rules = [], [{"type": "local", "tag": "bootstrap"}], [], []
        for exit_id, exit_ in self.exits.items():
            if node not in exit_["nodes"]:
                continue
            tag = "exit-" + exit_id
            options = secret_values(exit_.get("options", {}), self.secrets)
            concrete = options | {"type": "direct" if exit_["type"] == "native" else exit_["type"], "tag": tag,
                                  "domain_resolver": {"server": "bootstrap", "strategy": "prefer_ipv4"}}
            if exit_["type"] in {"wireguard", "openvpn-client"}:
                concrete["system"] = False
                endpoints.append(concrete)
            else:
                outbounds.append(concrete)
            users = [user["name"] for protocol in ("trojan", "hysteria2")
                     for user in self.credentials(node, protocol) if user["name"].split("/")[1] == exit_id]
            if users:
                resolvers = secret_values(exit_.get("dns", DEFAULT_DNS), self.secrets)
                if not resolvers:
                    raise ValueError("an exit requires at least one DNS server")
                for index, resolver in enumerate(resolvers):
                    ipaddress.ip_address(resolver["server"])
                    dns_tag = f"dns-{exit_id}-{index}"
                    dns.append(resolver | {"tag": dns_tag, "detour": tag})
                    dns_rules.append({"auth_user": users, "action": "evaluate", "server": dns_tag,
                                      "tag": dns_tag, "speculative": True})
                    # Both useful answers and authoritative absence win the race.
                    for rcode in ("NOERROR", "NXDOMAIN"):
                        dns_rules.append({"auth_user": users, "match_response": dns_tag,
                                          "response_rcode": rcode, "action": "respond", "race": True})
                dns_rules.append({"auth_user": users, "action": "predefined", "rcode": "SERVFAIL"})
                if not exit_.get("udp", True):
                    rules.append({"auth_user": users, "network": "udp", "action": "reject"})
                rules.extend([
                    {"auth_user": users, "action": "resolve",
                     "strategy": "prefer_ipv4" if exit_.get("ipv6", False) else "ipv4_only"},
                    {"auth_user": users, "ip_is_private": True, "action": "reject"},
                ])
                if not exit_.get("ipv6", False):
                    rules.append({"auth_user": users, "ip_version": 6, "action": "reject"})
                rules.append({"auth_user": users, "action": "route", "outbound": tag})
        rules.append({"action": "reject"})
        return {
            "log": {"level": "info", "timestamp": True},
            "inbounds": [
                {"type": "trojan", "tag": "trojan", "listen": "127.0.0.1", "listen_port": 14443,
                 "users": self.credentials(node, "trojan"), "tls": tls},
                {"type": "hysteria2", "tag": "hysteria2", "listen": "0.0.0.0", "listen_port": self.port(node),
                 "users": self.credentials(node, "hysteria2"), "tls": tls},
            ],
            "outbounds": outbounds, "endpoints": endpoints,
            "dns": {"servers": dns, "rules": dns_rules, "final": "bootstrap"},
            "route": {"rules": rules, "auto_detect_interface": True, "default_domain_resolver": "bootstrap"},
        }

    def provider(self, subscription_id):
        subscription = self.subscriptions[subscription_id]
        outbounds, exits = [], {}
        entries = subscription.get("entries", list(self.nodes))
        if not entries or not set(entries) <= self.nodes.keys():
            raise ValueError("subscription entries must name existing nodes")
        for exit_id in subscription["exits"]:
            exit_ = self.exits[exit_id]
            members = []
            for entry in entries:
                for carrier in exit_["nodes"]:
                    for protocol in ("trojan", "hysteria2"):
                        tag = f"path-{entry}-{carrier}-{exit_id}-{protocol}"
                        members.append(tag)
                        outbounds.append({
                            "type": protocol, "tag": tag, "server": self.nodes[entry]["address"],
                            "server_port": 443 if protocol == "trojan" else self.port(carrier),
                            "password": self.password(subscription_id, exit_id, protocol),
                            "tls": {"enabled": True, "server_name": self.nodes[carrier]["serverName"]},
                        })
            exits[exit_id] = {"paths": members, "udp": exit_.get("udp", True)}
        return {"outbounds": outbounds, "endpoints": [], "exits": exits,
                "groups": copy.deepcopy(subscription["groups"])}

    def metadata(self):
        result = {"nodes": {}}
        for name, node in self.nodes.items():
            cert = self.certificate_request(name)
            result["nodes"][name] = {
                key: copy.deepcopy(value) for key, value in node.items()
                if key in {"address", "serverName", "udpSlot", "uefi", "disk", "interface", "dhcp",
                           "addresses", "gateway", "nameservers", "sshHost", "sshServer",
                           "swapMiB", "tags", "modules", "web"}
            } | {"udpPort": self.port(name), "release": digest([self.server(name), cert])[:32],
                 "certificateId": digest(cert["names"])[:16]}
        return result

    def certificate_request(self, node):
        worker = self.data["workers"]["certificates"]
        return {"url": worker["url"].rstrip("/") + "/" + node,
                "token": self.secrets[self.nodes[node]["certificateToken"]],
                "serverName": self.nodes[node]["serverName"],
                "names": [self.nodes[node]["serverName"], *self.nodes[node].get("web", {})]}
