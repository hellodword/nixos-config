#!/usr/bin/env python3
"""Apply domain classification and optional DNS transports to sing-box."""
import argparse
import copy
import json
from pathlib import Path
import domain_policy


def assemble(base, policy, transports=(), model=None, ipv4_only=False):
    base = copy.deepcopy(base)
    defaults = base.pop("_connectionFragments", {})
    model = model or domain_policy.compile_policy(policy | {"connectionFragments": defaults | policy.get("connectionFragments", {})})
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
