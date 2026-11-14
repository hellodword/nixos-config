#!/usr/bin/env python3
"""Apply domain classification and optional DNS transports to sing-box."""
import argparse
import copy
import json
from pathlib import Path
import domain_policy


def fakeip_rules(route, exclusions, ipv4_only):
    """Use the shared first-match policy to select synthetic or real answers."""
    real = {"action": "route", "server": "dns-policy"}
    rules = [
        {"query_type": ["A", "AAAA", "HTTPS", "SVCB"], "invert": True, **real},
        {"domain_suffix": ["lan", "local", "localhost", "home.arpa", "ts.net", "tailscale.com", "tailscale.io"], **real},
    ]
    if not isinstance(exclusions, dict) or set(exclusions) - {"domain", "domain_suffix"}:
        raise ValueError("FakeIP exclusions require domain and domain_suffix arrays")
    if any(not isinstance(values, list) for values in exclusions.values()):
        raise ValueError("FakeIP exclusions require domain and domain_suffix arrays")
    names = {key: values for key, values in exclusions.items() if values}
    if names:
        rules.append(domain_policy.condition(names, "FakeIP exclusions", {}) | real)

    def public_answers(match):
        empty = {"query_type": ["HTTPS", "SVCB"] + (["AAAA"] if ipv4_only else [])}
        if match:
            empty = {"type": "logical", "mode": "and", "rules": [match, empty]}
        return [empty | {"action": "predefined", "rcode": "NOERROR"},
                match | {"action": "route", "server": "dns-fakeip"}]

    for rule in route["rules"]:
        match = {key: value for key, value in rule.items() if key not in {"action", "outbound"}}
        if rule.get("action") == "route" and rule.get("outbound") not in {"private", "tailnet"}:
            rules.extend(public_answers(match))
        else:
            rules.append(match | real)
    if route["final"] not in {"private", "tailnet"}:
        rules.extend(public_answers({}))
    return rules


def assemble(base, policy, transports=(), model=None, ipv4_only=False, fakeip_exclusions=None):
    base = copy.deepcopy(base)
    defaults = base.pop("_connectionFragments", {})
    model = model or domain_policy.compile_policy(policy | {"connectionFragments": defaults | policy.get("connectionFragments", {})})
    if base.pop("_fakeIP", False):
        base["dns"]["rules"] = fakeip_rules(model["route"], fakeip_exclusions or {}, ipv4_only)
    tunnels = []
    for transport in transports:
        inbound = {"type": "direct", "tag": transport["tag"], "listen": "127.0.0.1",
                   "listen_port": transport["listen_port"], "override_address": transport["address"],
                   "override_port": transport["port"]}
        if "network" in transport:
            inbound["network"] = transport["network"]
        base["inbounds"].append(inbound)
        tunnels.append({"inbound": [transport["tag"]], "action": "route", "outbound": transport["outbound"]})
    route = model["connection_route"]
    base["route"]["rules"] = tunnels + base["route"]["rules"] + route["rules"]
    base["route"]["rule_set"] = route["rule_set"]
    base["route"]["final"] = route["final"]
    base["_purposeGroups"] = policy.get("purposeGroups", [])
    if ipv4_only:
        base["_ipv4Only"] = True
        base["inbounds"] = [inbound for inbound in base["inbounds"] if ":" not in inbound.get("listen", "")]
    return base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--transports", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text())
    transports = json.loads(args.transports.read_text()) if args.transports else []
    base = json.loads(args.base.read_text())
    policy["connectionFragments"] = base.get("_connectionFragments", {}) | policy.get("connectionFragments", {})
    model = domain_policy.compile_policy(policy)
    args.output.write_text(json.dumps(assemble(base, policy, transports, model)) + "\n")
    (args.output.parent / "summary.json").write_text(json.dumps(model["summary"]) + "\n")


if __name__ == "__main__":
    main()
