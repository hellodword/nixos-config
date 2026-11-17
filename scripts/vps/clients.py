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
from render import grouped_outbounds
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


def mobile(provider):
    config = json.loads((DATA / "sing-box-client.json").read_text())
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
    for name in provider["groups"]:
        if name != "proxy":
            config["dns"]["servers"].append(copy.deepcopy(prototype) | {"tag": "dns-" + name, "detour": name})
    route, dns = purposes.sing_box(provider["groups"])
    config["route"]["rule_set"] = route["rule_set"]
    config["route"]["rules"].extend(route["rules"])
    rules = []
    for rule in config["route"]["rules"]:
        if rule.get("outbound") == "direct":
            # Resolve through DNS policy before dialing; the dialer's resolver is a single transport.
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
        lines.append(f"{node['type']}://{quote(node['password'], safe='')}@{node['server']}:{node['server_port']}"
                     f"/?{urlencode(parameters)}#{quote(node['tag'], safe='')}")
    return base64.b64encode(("\n".join(lines) + "\n").encode()).decode() + "\n"


def shadowrocket(provider, subscription_name=None):
    general, _, rules = (DATA / "shadowrocket-client.conf").read_text().partition("[Rule]\n")
    lines = [general.rstrip()]
    for protocol, setting in (("https", "dns-server"), ("tls", "fallback-dns-server")):
        urls = []
        for upstream in DIRECT_DNS:
            if upstream["protocol"] == protocol:
                port = "" if upstream["port"] == (443 if protocol == "https" else 853) else f":{upstream['port']}"
                urls.append(f"{protocol}://{upstream['address']}{port}{upstream.get('path', '')}")
        lines.append(setting + " = " + ", ".join(urls))
    if subscription_name is None:
        lines += ["", "[Proxy]"]
        for node in provider["outbounds"]:
            lines.append(f"{node['tag']} = {node['type']}, {node['server']}, {node['server_port']}, "
                         f"password={json.dumps(node['password'])}, sni={node['tls']['server_name']}, "
                         "skip-cert-verify=false, udp-relay=true")
    lines += ["", "[Proxy Group]"]
    for name, exit_ in provider["exits"].items():
        if subscription_name is None:
            members = ", ".join(exit_["paths"])
        else:
            pattern = "^(?:" + "|".join(re.escape(path) for path in exit_["paths"]) + ")$"
            members = f"{subscription_name}, use=true, policy-regex-filter={pattern}"
        lines.append(f"exit-{name}-auto = url-test, {members}" +
                     ", url=https://www.gstatic.com/generate_204, interval=600, tolerance=0, timeout=5")
        lines.append(f"exit-{name} = select, exit-{name}-auto, {members}")
    for name, binding in provider["groups"].items():
        choices = [binding["default"], *(e for e in binding["exits"] if e != binding["default"])]
        lines.append(f"{name} = select, " + ", ".join("exit-" + e for e in choices))
    lines += ["", "[Rule]", rules.rstrip()]
    lines.extend(purposes.shadowrocket(provider["groups"]))
    return "\n".join([*lines, ""])
