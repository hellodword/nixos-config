"""Insert authorized paths into the native client configuration and rule catalog."""
import base64
import copy
import json
from pathlib import Path
import re
import sys
import tomllib
from urllib.parse import quote, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "network"))
from provider_groups import grouped_outbounds, purpose_group
import purposes

DATA = Path(__file__).resolve().parents[2] / "data/network"
DIRECT_DNS = tomllib.loads((DATA / "direct-dns.toml").read_text())["upstreams"]


def direct_dns_rules(rules, servers):
    result = []
    for index, rule in enumerate(rules):
        if rule.get("server") != "dns-direct":
            result.append(rule)
            continue
        match = {key: value for key, value in rule.items() if key not in {"action", "server"}}
        for server in servers:
            tag = f"direct-{index}-{server}"
            result.append(match | {"action": "evaluate", "server": server, "tag": tag,
                                   "speculative": server != servers[0], "timeout": "4s"})
            for rcode in ("NOERROR", "NXDOMAIN"):
                # Each response tag exists only when its query condition matched.
                result.append({"match_response": tag, "response_rcode": rcode,
                               "action": "respond", "race": True})
        result.append(match | {"action": "predefined", "rcode": "SERVFAIL"})
    return result


DOMAIN_FIELDS = {"domain", "domain_suffix", "domain_keyword", "domain_regex"}
IP_FIELDS = {"ip_cidr", "ip_is_private", "source_ip_cidr", "source_ip_is_private"}


def rule_set_tags(rule):
    raw = rule.get("rule_set", [])
    tags = {raw} if isinstance(raw, str) else set(raw)
    for child in rule.get("rules", []):
        tags.update(rule_set_tags(child))
    return tags


def has_ip_criteria(rule, domain_sets):
    if rule.get("type") == "logical":
        return any(has_ip_criteria(child, domain_sets) for child in rule.get("rules", []))
    tags = rule_set_tags(rule)
    return bool(IP_FIELDS.intersection(rule) or (tags - domain_sets))


def needs_domain_resolve(rule, domain_sets):
    if rule.get("type") == "logical":
        children = rule.get("rules", [])
        if rule.get("mode") == "and":
            return (
                any(needs_domain_resolve(child, domain_sets) for child in children)
                and not any(has_ip_criteria(child, domain_sets) for child in children)
            )
        return any(needs_domain_resolve(child, domain_sets) for child in children)
    return bool(DOMAIN_FIELDS.intersection(rule) or (rule_set_tags(rule) & domain_sets))


def mobile(provider, cache_id=None):
    config = json.loads((DATA / "sing-box-client.json").read_text())
    if cache_id is not None:
        config["experimental"]["cache_file"]["cache_id"] = cache_id
    direct_servers = []
    for index, upstream in enumerate(DIRECT_DNS):
        tag = f"dns-direct-{index}"
        direct_servers.append(tag)
        server = {"tag": tag, "type": upstream["protocol"], "server": upstream["address"],
                  "server_port": upstream["port"],
                  "tls": {"enabled": True, "server_name": upstream["serverName"]}}
        if "path" in upstream:
            server["path"] = upstream["path"]
        config["dns"]["servers"].append(server)
    config["route"]["default_domain_resolver"] = direct_servers[0]
    prototype = next(server for server in config["dns"]["servers"] if server["tag"] == "dns-proxy")
    groups = provider["groups"]
    primary = purpose_group("proxy", groups)
    prototype.update(tag="dns-" + primary, detour=primary)
    for name, binding in groups.items():
        if isinstance(binding, dict) and name != primary:
            config["dns"]["servers"].append(copy.deepcopy(prototype) | {"tag": "dns-" + name, "detour": name})
    route, dns = purposes.sing_box(groups)
    domain_sets = {tag for item in dns["rules"] for tag in rule_set_tags(item)}
    config["route"]["rule_set"] = route["rule_set"]
    config["route"]["rules"].extend(route["rules"])
    rules = []
    for rule in config["route"]["rules"]:
        if rule.get("outbound") == "direct" and needs_domain_resolve(rule, domain_sets):
            # Resolve domain-matched direct rules through DNS policy before dialing.
            rules.append({key: value for key, value in rule.items() if key != "outbound"} | {"action": "resolve"})
        rules.append(rule)
    config["route"]["rules"] = rules
    config["route"]["final"] = route["final"]
    config["dns"]["rules"].extend(direct_dns_rules(dns["rules"], direct_servers))
    config["dns"]["final"] = dns["final"]
    config["outbounds"].extend(grouped_outbounds(provider))
    config["outbounds"].extend(copy.deepcopy(provider["outbounds"]))
    return config


def shadowrocket_nodes(provider):
    lines = []
    for node in provider["outbounds"]:
        parameters = {"sni": node["tls"]["server_name"]}
        parameters["allowInsecure" if node["type"] == "trojan" else "insecure"] = "0"
        if "detour" in node:
            parameters["chain"] = node["detour"]
        host = node["server"]
        if ":" in host:
            host = f"[{host}]"
        lines.append(f"{node['type']}://{quote(node['password'], safe='')}@{host}:{node['server_port']}"
                     f"/?{urlencode(parameters)}#{quote(node['tag'], safe='')}")
    return base64.b64encode(("\n".join(lines) + "\n").encode()).decode() + "\n"


def shadowrocket(provider, subscription_name=None):
    parts = re.split(r"(?m)^\[Rule\][ \t]*(?:\r?\n|$)", (DATA / "shadowrocket-client.conf").read_text(), maxsplit=1)
    if len(parts) != 2:
        raise ValueError("shadowrocket-client.conf is missing a [Rule] section")
    general, rules = parts
    lines = [general.rstrip()]
    if any("detour" in node for node in provider["outbounds"]):
        lines.append("close-if-proxy-chain-missing = true")
    for protocol, setting in (("https", "dns-server"), ("tls", "fallback-dns-server")):
        urls = []
        for upstream in DIRECT_DNS:
            if upstream["protocol"] == protocol:
                port = "" if upstream["port"] == (443 if protocol == "https" else 853) else f":{upstream['port']}"
                urls.append(f"{protocol}://{upstream['address']}{port}{upstream.get('path', '')}")
        lines.append(setting + " = " + ", ".join(urls))
    udp_by_path = {
        path: exit_.get("udp", True)
        for exit_ in provider.get("exits", {}).values()
        for path in exit_.get("paths", [])
    }
    if subscription_name is None:
        lines += ["", "[Proxy]"]
        for node in provider["outbounds"]:
            udp = "true" if udp_by_path.get(node["tag"], True) else "false"
            chain = ", chain=" + node["detour"] if "detour" in node else ""
            lines.append(f"{node['tag']} = {node['type']}, {node['server']}, {node['server_port']}, "
                         f"password={json.dumps(node['password'])}, sni={node['tls']['server_name']}, "
                         f"skip-cert-verify=false, udp-relay={udp}" + chain)
    lines += ["", "[Proxy Group]"]
    paths = {node["tag"] for node in provider["outbounds"]}
    for group in grouped_outbounds(provider):
        members = group["outbounds"]
        if subscription_name is not None:
            pattern = "^(?:" + "|".join(re.escape(tag) for tag in members if tag in paths) + ")$"
            members = [tag for tag in members if tag not in paths] + [
                subscription_name, "use=true", "policy-regex-filter=" + pattern]
        if group["type"] == "urltest":
            kind = "url-test"
            options = ["url=" + group["url"], "interval=600", "tolerance=0", "timeout=5", "hidden=1"]
        else:
            kind = "select"
            options = ["policy-select-name=" + group["default"]]
        lines.append(group["tag"] + " = " + ", ".join([kind, *members, *options]))
    lines += ["", "[Rule]", rules.rstrip()]
    lines.extend(purposes.shadowrocket(provider["groups"]))
    return "\n".join([*lines, ""])
