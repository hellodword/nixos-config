"""Project the ordered client policy into native sing-box and Shadowrocket rules."""
import copy
from pathlib import Path
import tomllib


CATALOG = tomllib.loads((Path(__file__).resolve().parents[2] / "data/network/purposes.toml").read_text())


def native_rule(rule):
    result = {key: copy.deepcopy(value) for key, value in rule.items() if key not in {"scope", "shadowrocket"}}
    if "rules" in result:
        result["rules"] = [native_rule(child) for child in result["rules"]]
    return result


def rule_sets(catalog=CATALOG):
    return [copy.deepcopy(catalog["rule_set_defaults"]) |
            {key: value for key, value in definition.items() if key not in {"shadowrocket", "seed"}} |
            {"tag": tag} for tag, definition in catalog["rule_sets"].items()]


def outbound(name, groups):
    return name if name in {"direct", "proxy"} or name in groups else "proxy"


def sing_box(groups, catalog=CATALOG):
    rules, dns = [], []
    for entry in catalog["rules"]:
        rule = native_rule(entry)
        if "outbound" in rule:
            rule["outbound"] = outbound(rule["outbound"], groups)
        rules.append(rule)
        if entry["scope"] == "domain":
            query = copy.deepcopy(rule)
            if query.get("action") == "route":
                query["server"] = "dns-" + query.pop("outbound")
            else:
                query.update(action="predefined", rcode="NXDOMAIN")
            dns.append(query)
    final = outbound(catalog["final"], groups)
    return {"rules": rules, "rule_set": rule_sets(catalog), "final": final}, {"rules": dns, "final": "dns-" + final}


def logical_match(mode, matches):
    return matches[0] if len(matches) == 1 else mode + ",(" + ",".join(f"({match})" for match in matches) + ")"


def shadowrocket_matches(rule, catalog):
    if "shadowrocket" in rule:
        return rule["shadowrocket"]
    if rule.get("type") == "logical":
        children = [shadowrocket_matches(child, catalog) for child in rule["rules"]]
        if rule["mode"] == "and" and any(not matches for matches in children):
            return []
        parts = [logical_match("OR", matches) for matches in children if matches]
        return [logical_match(rule["mode"].upper(), parts)] if parts else []
    fields = set(rule) - {"scope", "action", "outbound", "network"}
    domains = {"domain", "domain_suffix", "domain_keyword"}
    if fields - domains - {"port", "ip_cidr", "rule_set"} or (
            fields & domains and fields - domains):
        raise ValueError("provide native Shadowrocket matches for this condition")
    matches = []
    for field, kind in (("domain", "DOMAIN"), ("domain_suffix", "DOMAIN-SUFFIX"),
                        ("domain_keyword", "DOMAIN-KEYWORD"), ("port", "DST-PORT")):
        matches.extend(f"{kind},{value}" for value in rule.get(field, []))
    matches.extend(f"{'IP-CIDR6' if ':' in value else 'IP-CIDR'},{value}"
                   for value in rule.get("ip_cidr", []))
    for tag in rule.get("rule_set", []):
        matches.extend(catalog["rule_sets"][tag]["shadowrocket"])
    if "network" in rule:
        matches = [logical_match("AND", [f"PROTOCOL,{rule['network'].upper()}", match]) for match in matches]
    return matches


def shadowrocket(groups, catalog=CATALOG):
    lines = []
    for rule in catalog["rules"]:
        # Shadowrocket resolves domain targets when a GEOIP condition needs an address.
        if rule["action"] == "resolve":
            continue
        destination = "REJECT" if rule["action"] == "reject" else outbound(rule["outbound"], groups)
        destination = "DIRECT" if destination == "direct" else destination
        ip_rule = "ip_cidr" in rule or (rule["scope"] == "connection" and "rule_set" in rule)
        for match in shadowrocket_matches(rule, catalog):
            # Only literal IP traffic reaches the service/CN IP fallback.
            line = f"{match},{destination}" + (",no-resolve" if ip_rule else "")
            lines.append(line)
    lines.append("FINAL," + outbound(catalog["final"], groups))
    return lines
