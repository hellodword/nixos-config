#!/usr/bin/env python3
"""Compile DNS classification, encrypted races and optional transport requests."""
import argparse
import ipaddress
import json
import re
from pathlib import Path
import domain_policy


def lua(value):
    if isinstance(value, str):
        # JSON's unicode escapes are not Lua escapes. Our strings are ASCII.
        if not value.isascii():
            raise ValueError("use ASCII / IDNA names in network policy")
        return json.dumps(value)
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "{" + ",".join(map(lua, value)) + "}"
    return "{" + ",".join(f"[{lua(k)}]={lua(v)}" for k, v in value.items()) + "}"


def compile_policy(config, destination, model=None, ipv4_only=False):
    if set(config.get("groups", {})) != {"cn", "global"}:
        raise ValueError("DNS policy requires both cn and global resolver groups")
    destination.mkdir(parents=True, exist_ok=True)
    model = model or domain_policy.compile_policy(config, include_connections=False)
    front = config.get("frontPort", 5300)
    bootstrap = config.get("bootstrapPort", 5301)
    listeners = [("127.0.0.1", front), ("127.0.0.1", bootstrap)]
    if not ipv4_only:
        listeners.append(("::1", front))
    if front == bootstrap or any(type(port) is not int or not 1024 <= port <= 65535 for port in (front, bootstrap)):
        raise ValueError("DNS listeners must use distinct unprivileged ports")
    lines = [
        "-- Generated from ordered sing-box route fragments.",
        f"setLocal('127.0.0.1:{front}')",
        f"addLocal('127.0.0.1:{bootstrap}')",
        "setACL({'127.0.0.0/8', '::1/128'})",
        "setSecurityPollSuffix('')", "setRingBuffersSize(0)",
        "setUDPTimeout(6)", "setServFailWhenNoServer(true)",
        "setVerbose(false)",
    ]
    if not ipv4_only:
        lines.append(f"addLocal('[::1]:{front}')")
    socket_path = config.get("logSocket", "/run/site-dns-events/dnstap.sock")
    lines.extend([
        f"local tap = newFrameStreamUnixLogger({lua(socket_path)}, {{bufferHint=1024,flushTimeout=1,queueNotifyThreshold=1,reopenInterval=1}})",
        "local function exactNames(values)",
        " local names = newDNSNameSet()",
        " for _, name in ipairs(values) do names:add(newDNSName(name)) end",
        " return QNameSetRule(names)",
        "end",
        "local function annotate(source)",
        " return function(dq, message)",
        "  local metadata = dq:getTag('policy') or '{}'",
        "  message:setExtra(metadata:sub(1,-2) .. ',\"response_source\":\"' .. source .. '\"}')",
        " end",
        "end",
    ])
    def record(selector, metadata, identity="dnsdist-client"):
        metadata = {"generation": model["dns_generation"], **metadata}
        lines.extend([
            f"addAction({selector}, SetTagAction('policy', {lua(json.dumps(metadata, separators=(',', ':')))}))",
            f"addAction({selector}, DnstapLogAction({lua(identity)}, tap, annotate('query')))",
        ])

    for hook, source in (("addResponseAction", "upstream"), ("addCacheHitResponseAction", "cache"), ("addSelfAnsweredResponseAction", "self")):
        lines.append(f"{hook}(TagRule('race-leg','1'), DnstapLogResponseAction('dnsdist-leg', tap, annotate({lua(source)})))")
        lines.append(f"{hook}(NotRule(TagRule('race-leg','1')), DnstapLogResponseAction('dnsdist-client', tap, annotate({lua(source)})))")
    if ipv4_only:
        record("QTypeRule(DNSQType.AAAA)", {"rule": "listener/ipv4-only", "group": "local"})
        lines.append("addAction(QTypeRule(DNSQType.AAAA), RCodeAction(DNSRCode.NOERROR))")
    tunnels, occupied = [], {front, bootstrap}

    def reserve(port):
        if type(port) is not int or not 1024 <= port <= 65535 or port in occupied:
            raise ValueError("DNS internal ports must be distinct and unprivileged")
        occupied.add(port)
        return port

    def tunnel(tag, address, port, outbound, transport="tcp"):
        ipaddress.ip_address(address)
        listen = reserve(config.get("tunnelPortBase", 5600) + len(tunnels))
        tunnels.append({"tag": tag, "listen_port": listen, "address": address,
                        "port": port, "outbound": outbound})
        if transport:
            tunnels[-1]["network"] = transport
        return f"127.0.0.1:{listen}"

    leg_index = 0
    for index, (group, settings) in enumerate(config["groups"].items()):
        race = reserve(config.get("racePortBase", 5500) + index)
        upstreams = []
        for upstream in settings["upstreams"]:
            if ipv4_only and ipaddress.ip_address(upstream["address"]).version == 6:
                continue
            protocol = upstream["protocol"]
            if type(upstream["port"]) is not int or not 1 <= upstream["port"] <= 65535:
                raise ValueError("invalid encrypted DNS upstream port")
            if protocol not in {"tls", "https"}:
                raise ValueError("public DNS must use authenticated DoT or DoH")
            leg = reserve(config.get("legPortBase", 5400) + leg_index)
            listeners.append(("127.0.0.1", leg))
            tag = f"dns-{group}-{leg_index}"
            leg_index += 1
            ipaddress.ip_address(upstream["address"])
            address = (f"[{upstream['address']}]" if ":" in upstream["address"] else upstream["address"]) + f":{upstream['port']}"
            if group in config.get("tunnelGroups", []):
                address = tunnel(tag, upstream["address"], upstream["port"],
                                 "direct" if group == "cn" else "proxy")
            options = {
                "name": tag, "address": address, "pool": tag, "tls": "openssl",
                "subjectName": upstream["serverName"], "validateCertificates": True,
                "caStore": config.get("caStore", "/etc/ssl/certs/ca-certificates.crt"),
                "healthCheckMode": "up", "tcpConnectTimeout": 2,
                "tcpSendTimeout": 2, "tcpRecvTimeout": 2,
                "useClientSubnet": True,
            }
            if protocol == "https":
                options["dohPath"] = upstream.get("path", "/dns-query")
            ecs4 = str(ipaddress.ip_network(settings.get("ecs4", "0.0.0.0/0"), strict=True))
            ecs6 = str(ipaddress.ip_network(settings.get("ecs6", "::/0"), strict=True))
            if ipaddress.ip_network(ecs4).version != 4 or ipaddress.ip_network(ecs6).version != 6:
                raise ValueError("ECS prefixes must have the declared address family")
            lines.extend([
                f"addLocal('127.0.0.1:{leg}')", f"newServer({lua(options)})",
                f"addAction(DSTPortRule({leg}), SetTagAction('race-leg', '1'))",
                f"addAction(DSTPortRule({leg}), SetECSOverrideAction(true))",
                f"addAction(DSTPortRule({leg}), SetECSAction({lua(ecs4)}, {lua(ecs6)}))",

            ])
            record(f"DSTPortRule({leg})", {"group": group, "leg": tag, "upstream": upstream}, "dnsdist-leg")
            lines.append(f"addAction(DSTPortRule({leg}), PoolAction({lua(tag)}))")
            upstreams.append(f"tcp://127.0.0.1:{leg}")
        if len(upstreams) < (1 if ipv4_only else 2):
            raise ValueError("each DNS group needs an IPv4 upstream" if ipv4_only else "a race group requires at least two independent branches")
        (destination / f"race-{group}.json").write_text(json.dumps({
            "listen-addrs": ["127.0.0.1"], "listen-ports": [race],
            "upstream": upstreams, "upstream-mode": "parallel", "timeout": "4s",
            "cache": False, "edns": False, "hosts-file-enabled": False,
            "pending-requests-enabled": True, "use-private-rdns": False, "verbose": True,
        }, indent=2) + "\n")
        lines.append("newServer(" + lua({"name": "race-" + group, "address": f"127.0.0.1:{race}",
                     "pool": group, "healthCheckMode": "up", "tcpRecvTimeout": 6}) + ")")
        lines.append(f"getPool({lua(group)}):setCache(newPacketCache(10000, "
                     "{maxTTL=86400,minTTL=0,maxNegativeTTL=60,temporaryFailureTTL=0,dontAge=false}))")
    lines.extend([
        "local bad = AndRule({TagRule('race-leg','1'), NotRule(OrRule({ERCodeRule(DNSRCode.NOERROR),ERCodeRule(DNSRCode.NXDOMAIN)}))})",
        "addResponseAction(bad, DropResponseAction())",
        "addSelfAnsweredResponseAction(bad, DropResponseAction())",
    ])
    record("EDNSOptionRule(8)", {"rule": "listener/client-ecs", "group": "refused"})
    lines.append("addAction(EDNSOptionRule(8), RCodeAction(DNSRCode.REFUSED))")
    tailnet = config.get("tailnetUpstream")
    if tailnet:
        tag = "dns-tailnet"
        address = ((f"[{tailnet['address']}]" if ":" in tailnet["address"] else tailnet["address"])
                   + f":{tailnet.get('port', 53)}")
        lines.append("newServer(" + lua({"name": tag, "address": address,
                     "pool": "tailnet", "healthCheckMode": "up"}) + ")")

    def combine(operator, items):
        if not items:
            return "NotRule(AllRule())"
        return items[0] if len(items) == 1 else operator + "({" + ",".join(items) + "})"

    def selector(rule):
        if rule.get("type") == "logical":
            result = combine("AndRule" if rule["mode"] == "and" else "OrRule", [selector(child) for child in rule["rules"]])
        else:
            items = []
            if "domain" in rule:
                items.append(f"exactNames({lua(rule['domain'])})")
            if "domain_suffix" in rule:
                suffixes = [name for name in rule["domain_suffix"] if not name.startswith(".")]
                if suffixes:
                    items.append(f"SuffixMatchNodeRule({lua(suffixes)})")
                items.extend(f"AndRule({{SuffixMatchNodeRule({lua(name[1:])}),NotRule(QNameRule({lua(name[1:])}))}})"
                             for name in rule["domain_suffix"] if name.startswith("."))
            for pattern in rule.get("domain_regex", []) + [re.escape(word) for word in rule.get("domain_keyword", [])]:
                items.append(f"RE2Rule({lua(model['regexes'][pattern])})")
            items.extend(set_selectors[tag] for tag in rule.get("rule_set", []))
            result = combine("OrRule", items)
        return f"NotRule({result})" if rule.get("invert", False) else result

    set_selectors = {}
    for index, (tag, rules) in enumerate(model["sets"].items()):
        # Each scope also bounds Lua's number of local variables.
        lines.append(f"local rs{index}; do")
        value = combine("OrRule", [selector(rule) for rule in rules])
        lines.extend([f"rs{index} = {value}", "end"])
        set_selectors[tag] = f"rs{index}"

    def references(rule):
        return sorted(set(rule.get("rule_set", [])) | {tag for child in rule.get("rules", []) for tag in references(child)})

    def decision(match, rule, location):
        outbound = rule.get("outbound", "reject")
        group = {"direct": "cn", "proxy": "global", "private": "private", "tailnet": "tailnet", "reject": "reject"}[outbound]
        metadata = {"rule": location, "group": group, "outbound": outbound,
                    "rule_sets": {tag: model["summary"]["rule_sets"][tag] for tag in references(rule)}}
        if group == "tailnet":
            if not tailnet:
                raise ValueError(f"{location}: tailnet requires a DNS upstream binding")
            metadata["upstream"] = tailnet
        lines.append("do")
        value = match() if callable(match) else match
        lines.append(f"local selected = {value}")
        if group in {"cn", "global"}:
            # Node bootstrap shares domain protection, but uses CN transport.
            bootstrap_match = f"AndRule({{selected,DSTPortRule({bootstrap})}})"
            record(bootstrap_match, {**metadata, "group": "cn", "listener": "bootstrap"})
            lines.append(f"addAction({bootstrap_match}, PoolAction('cn'))")
        record("selected", metadata)
        action = "RCodeAction(DNSRCode.NXDOMAIN)" if group in {"private", "reject"} else f"PoolAction({lua(group)})"
        lines.extend([f"addAction(selected, {action})", "end"])

    for rule, provenance in zip(model["route"]["rules"], model["summary"]["rules"]):
        decision(lambda: selector(rule), rule, provenance["rule"])
    decision("AllRule()", {"outbound": model["route"]["final"]}, model["summary"]["final_source"])
    (destination / "dnsdist.conf").write_text("\n".join(lines) + "\n")
    (destination / "transports.json").write_text(json.dumps(tunnels) + "\n")
    (destination / "summary.json").write_text(json.dumps(model["summary"], indent=2) + "\n")
    return listeners


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    compile_policy(json.loads(args.policy.read_text()), args.output)


if __name__ == "__main__":
    main()
