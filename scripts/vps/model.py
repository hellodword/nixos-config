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


class DeclarationError(ValueError):
    """A field location and a safe explanation, without its supplied value."""

    def __init__(self, path, reason):
        super().__init__(f"{path}: {reason}")


def field(mapping, key, kind, path, default=...):
    location = f"{path}.{key}" if path else key
    if not isinstance(mapping, dict):
        raise DeclarationError(path or "inventory", "expected a mapping")
    if key not in mapping:
        if default is not ...:
            return default
        raise DeclarationError(location, "required field is missing")
    value = mapping[key]
    if not isinstance(value, kind):
        names = {dict: "a mapping", list: "a list", str: "text", int: "an integer"}
        raise DeclarationError(location, "expected " + names[kind])
    return value


def require(condition, path, reason):
    if not condition:
        raise DeclarationError(path, reason)


def references(values, choices, path, *, distinct=True):
    require(isinstance(values, list) and bool(values), path, "select at least one entry")
    require(all(isinstance(value, str) and value in choices for value in values), path,
            "each entry must name an existing authorized item")
    if distinct:
        require(len(set(values)) == len(values), path, "entries must be distinct")


def identifier(value, path="identifier"):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", value):
        raise DeclarationError(path, "use lowercase letters, digits and hyphens, starting with a letter")
    return value


def secret_values(value, secrets, path):
    if isinstance(value, dict):
        if set(value) == {"secret"}:
            name = value["secret"]
            require(isinstance(name, str) and name in secrets, path + ".secret", "referenced secret is not declared")
            return copy.deepcopy(secrets[name])
        return {key: secret_values(item, secrets, f"{path}.{key}") for key, item in value.items()}
    if isinstance(value, list):
        return [secret_values(item, secrets, f"{path}[{index}]") for index, item in enumerate(value)]
    return value


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Inventory:
    def __init__(self, document):
        self.data = copy.deepcopy(document)
        self.nodes = field(self.data, "nodes", dict, "")
        self.exits = field(self.data, "exits", dict, "")
        self.subscriptions = field(self.data, "subscriptions", dict, "", {})
        self.secrets = field(self.data, "secrets", dict, "", {})
        self.validate_nodes()
        self.validate_exits()
        self.validate_subscriptions()

    def validate_nodes(self):
        slots, snis = set(), set()
        for name, node in self.nodes.items():
            identifier(name, "nodes")
            path = f"nodes.{name}"
            address = field(node, "address", str, path)
            try:
                ipaddress.IPv4Address(address)
            except ValueError:
                raise DeclarationError(path + ".address", "expected an IPv4 address") from None
            slot = field(node, "udpSlot", int, path)
            require(type(slot) is int and 0 <= slot <= UDP_LAST - UDP_FIRST and slot not in slots,
                    path + ".udpSlot", f"use a unique integer between 0 and {UDP_LAST - UDP_FIRST}")
            slots.add(slot)
            sni = field(node, "serverName", str, path)
            require(re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", sni) and sni not in snis,
                    path + ".serverName", "use a unique DNS server name")
            snis.add(sni)
            ssh_host = field(node, "sshHost", str, path)
            require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", ssh_host),
                    path + ".sshHost", "expected a concrete SSH host alias")
            ssh = field(node, "sshServer", dict, path)
            require(field(ssh, "rootAuthorizedKeys", list, path + ".sshServer"),
                    path + ".sshServer.rootAuthorizedKeys", "supply at least one public key")
            interface = field(node, "interface", str, path, "eth0")
            require(re.fullmatch(r"[a-zA-Z0-9_.:-]{1,15}", interface), path + ".interface", "invalid interface name")
            for index, module in enumerate(field(node, "modules", list, path, [])):
                require(isinstance(module, str) and re.fullmatch(r"[a-zA-Z0-9_/-]+\.nix", module)
                        and not module.startswith("/") and ".." not in module.split("/"),
                        f"{path}.modules[{index}]", "use a repository-relative Nix path")
            for hostname, upstream in field(node, "web", dict, path, {}).items():
                require(isinstance(hostname, str) and re.fullmatch(r"[a-z0-9][a-z0-9.-]*", hostname)
                        and hostname != sni, path + ".web", "use DNS names distinct from the proxy SNI")
                try:
                    url = urlparse(upstream)
                    valid = url.scheme in {"http", "https"} and url.hostname in {"127.0.0.1", "::1", "localhost"}
                except (ValueError, TypeError, AttributeError):
                    valid = False
                require(valid, path + ".web." + hostname, "expected a local HTTP service URL")

    def validate_exits(self):
        for name, exit_ in self.exits.items():
            identifier(name, "exits")
            path = f"exits.{name}"
            carriers = field(exit_, "nodes", list, path)
            references(carriers, self.nodes, path + ".nodes")
            kind = field(exit_, "type", str, path)
            require(kind in {"native", "wireguard", "socks", "openvpn-client"}, path + ".type", "unsupported exit type")
            require(kind != "native" or len(carriers) == 1, path + ".nodes", "a native exit belongs to one node")
            options = field(exit_, "options", dict, path, {})
            secret_values(options, self.secrets, path + ".options")

    def validate_subscriptions(self):
        keys, paths, names = set(), set(), set()
        for name, subscription in self.subscriptions.items():
            identifier(name, "subscriptions")
            path = f"subscriptions.{name}"
            title = field(subscription, "name", str, path, name)
            require(title and title == title.strip() and not re.search(r'[\x00-\x1f\x7f,="/\\]', title)
                    and title.casefold() not in names, path + ".name", "use a distinct single-line client label")
            subscription["name"] = title
            names.add(title.casefold())
            route = field(subscription, "path", str, path)
            require(re.fullmatch(r"/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", route)
                    and route not in paths, path + ".path", "use a distinct /UUIDv4 path")
            paths.add(route)
            key = field(subscription, "key", str, path)
            require(re.fullmatch(r"[0-9a-fA-F]{64}", key), path + ".key", "supply 32 bytes encoded as hexadecimal")
            key = bytes.fromhex(key)
            require(key not in keys, path + ".key", "each subscription requires an independent key")
            keys.add(key)
            exits = field(subscription, "exits", list, path)
            references(exits, self.exits, path + ".exits")
            groups = field(subscription, "groups", dict, path)
            for group, binding in groups.items():
                identifier(group, path + ".groups")
                group_path = path + ".groups." + group
                require(group not in {"direct", "private", "tailnet", "local", "auto", "transparent", "cn", "global"},
                        group_path, "purpose group conflicts with a local route")
                choices = field(binding, "exits", list, group_path)
                references(choices, exits, group_path + ".exits", distinct=False)
                if "default" not in binding:
                    require(len(choices) == 1, group_path + ".default", "select a default when the group has multiple exits")
                    binding["default"] = choices[0]
                require(binding["default"] in choices, group_path + ".default", "select an exit from this group")
            require("proxy" in groups, path + ".groups.proxy", "a proxy group is required")

    def worker(self, name):
        workers = field(self.data, "workers", dict, "")
        return field(workers, name, dict, "workers")

    def secret(self, name, path):
        require(isinstance(name, str) and name in self.secrets, path, "referenced secret is not declared")
        return self.secrets[name]

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
            options = secret_values(exit_.get("options", {}), self.secrets, f"exits.{exit_id}.options")
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
                resolvers = secret_values(exit_.get("dns", DEFAULT_DNS), self.secrets, f"exits.{exit_id}.dns")
                require(isinstance(resolvers, list) and bool(resolvers), f"exits.{exit_id}.dns",
                        "supply at least one DNS server")
                for index, resolver in enumerate(resolvers):
                    location = f"exits.{exit_id}.dns[{index}]"
                    address = field(resolver, "server", str, location)
                    try:
                        ipaddress.ip_address(address)
                    except ValueError:
                        raise DeclarationError(location + ".server", "expected an IP address") from None
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
        references(entries, self.nodes, f"subscriptions.{subscription_id}.entries", distinct=False)
        for exit_id in subscription["exits"]:
            exit_ = self.exits[exit_id]
            members = []
            for entry in entries:
                for carrier in exit_["nodes"]:
                    hop = entry if entry == carrier else f"{entry} → {carrier}"
                    label = "native" if exit_["type"] == "native" and exit_id == f"{carrier}-native" else f"[{exit_id}]"
                    for protocol in ("trojan", "hysteria2"):
                        transport = "Trojan" if protocol == "trojan" else "HY2"
                        tag = f"{hop} · {label} · {transport}"
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
        worker = self.worker("certificates")
        return {"url": field(worker, "url", str, "workers.certificates").rstrip("/") + "/" + node,
                "token": self.secret(field(self.nodes[node], "certificateToken", str, f"nodes.{node}"), f"nodes.{node}.certificateToken"),
                "serverName": self.nodes[node]["serverName"],
                "names": [self.nodes[node]["serverName"], *self.nodes[node].get("web", {})]}
