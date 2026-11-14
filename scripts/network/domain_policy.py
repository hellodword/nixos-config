"""Resolve ordered sing-box route fragments for DNS and connection routing."""
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import rules as rule_updates


DOMAIN_FIELDS = {"domain", "domain_suffix", "domain_keyword", "domain_regex"}
OUTBOUNDS = {"direct", "proxy", "private", "tailnet"}


def read_json(path, tool="hujsonfmt"):
    """Standardize JSONC with HuJSON while leaving the editable source intact."""
    result = subprocess.run([tool, "-s"], input=path.read_bytes(), capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError(f"{path.name}: invalid JSONC")
    return json.loads(result.stdout)


def fragments(config, field, directory):
    values = copy.deepcopy(config.get(field, {}))
    sources = {name: "declarative" for name in values}
    if directory is not None and directory.exists():
        for path in directory.iterdir():
            if path.suffix in {".json", ".jsonc"}:
                values[path.name] = read_json(path, config.get("jsoncTool", "hujsonfmt"))
                sources[path.name] = str(path)
    for name, value in values.items():
        if Path(name).name != name or Path(name).suffix not in {".json", ".jsonc"}:
            raise ValueError(f"invalid fragment filename: {name}")
        if not isinstance(value, dict) or set(value) - {"rules", "rule_set", "final"}:
            raise ValueError(f"{name}: expected a route object with rules, rule_set or final")
        for key in ("rules", "rule_set"):
            if not isinstance(value.get(key, []), list):
                raise ValueError(f"{name}/{key}: expected an array")
    return values, sources


def strings(value, location):
    values = [value] if isinstance(value, str) else value
    if not isinstance(values, list) or not values or any(not isinstance(v, str) or not v or not v.isascii() for v in values):
        raise ValueError(f"{location}: expected nonempty ASCII string(s)")
    return values


def condition(rule, location, sets, headless=False):
    if not isinstance(rule, dict):
        raise ValueError(f"{location}: rule must be an object")
    logical = rule.get("type", "default") == "logical"
    fields = {"type", "invert"} | ({"rules", "mode"} if logical else DOMAIN_FIELDS | ({"rule_set"} if not headless else set()))
    if not headless:
        fields |= {"action", "outbound"}
    unknown = set(rule) - fields
    if unknown:
        raise ValueError(f"{location}: outside the shared domain route subset: {', '.join(sorted(unknown))}")
    if type(rule.get("invert", False)) is not bool:
        raise ValueError(f"{location}: invert must be boolean")
    result = {}
    if logical:
        if rule.get("mode") not in {"and", "or"} or not isinstance(rule.get("rules"), list) or not rule["rules"]:
            raise ValueError(f"{location}: logical rule requires mode and nonempty rules")
        result = {"type": "logical", "mode": rule["mode"], "rules": [
            condition(child, f"{location}/rules/{i}", sets, headless=headless)
            for i, child in enumerate(rule["rules"])]}
        if any("action" in child or "outbound" in child for child in rule["rules"]):
            raise ValueError(f"{location}: put the terminal action on the outer rule")
    else:
        if rule.get("type", "default") != "default":
            raise ValueError(f"{location}: unsupported rule type")
        if "rule_set" in rule and DOMAIN_FIELDS & rule.keys():
            raise ValueError(f"{location}: combine rule_set and domain conditions with explicit logical and/or")
        for field in sorted(DOMAIN_FIELDS | {"rule_set"}):
            if field not in rule:
                continue
            values = strings(rule[field], f"{location}/{field}")
            if field in {"domain", "domain_suffix"}:
                if any(v != v.lower() or v.endswith(".") or not re.fullmatch(r"\.?[a-z0-9_-]+(?:\.[a-z0-9_-]+)*", v) for v in values):
                    raise ValueError(f"{location}/{field}: use lowercase names without a trailing dot")
                if field == "domain" and any(v.startswith(".") for v in values):
                    raise ValueError(f"{location}/{field}: exact names cannot start with a dot")
            if field == "rule_set" and any(v not in sets for v in values):
                raise ValueError(f"{location}: unknown rule_set tag")
            result[field] = values
        if not result:
            raise ValueError(f"{location}: expected a domain condition")
    if rule.get("invert", False):
        result["invert"] = True
    return result


def remote_rule_sets(config, directory=None):
    shared, _ = fragments(config, "routeFragments", directory)
    definitions = {definition["tag"]: definition for name in sorted(shared)
                   for definition in shared[name].get("rule_set", [])}
    return [definition for definition in definitions.values() if definition.get("type") == "remote"]


def rule_set_document(definition, location, config, rule_paths=None):
    kind = definition.get("type", "inline")
    if kind == "remote":
        key = rule_updates.remote_source(definition)
        definition = {"type": "local", "tag": definition["tag"], "format": definition["format"],
                      "path": str((rule_paths or {}).get(key, definition["initial_path"]))}
        kind = "local"
    if kind == "inline" and set(definition) <= {"type", "tag", "rules"}:
        document = {"rules": definition.get("rules")}
    elif kind == "local" and set(definition) <= {"type", "tag", "format", "path"}:
        path = Path(definition["path"])
        if not path.is_absolute():
            raise ValueError(f"{location}: use an absolute rule_set path")
        format_ = definition.get("format", "binary" if path.suffix == ".srs" else "source")
        if format_ == "binary":
            with tempfile.TemporaryDirectory(prefix="route-ruleset-") as temporary:
                output = Path(temporary) / "rules.json"
                subprocess.run([config.get("ruleSetTool", "sing-box"), "rule-set", "decompile", str(path), "--output", str(output)],
                               check=True, capture_output=True, timeout=120)
                document = json.loads(output.read_text())
        elif format_ == "source":
            document = read_json(path, config.get("jsoncTool", "hujsonfmt"))
        else:
            raise ValueError(f"{location}: use source or binary format")
        if document.get("version") not in {1, 2, 3, 4}:
            raise ValueError(f"{location}: unsupported source rule_set version")
    else:
        raise ValueError(f"{location}: use an inline, local or shared remote rule_set")
    if not isinstance(document.get("rules"), list):
        raise ValueError(f"{location}: rule_set requires a rules array")
    return document


def compile_policy(config, directory=None, connection_directory=None, include_connections=True, rule_paths=None):
    outbounds = OUTBOUNDS | set(config.get("purposeGroups", []))
    shared, sources = fragments(config, "routeFragments", directory)
    files, rules, definitions = [], [], {}
    final, final_source = "proxy", "implicit final"
    for filename in sorted(shared, key=lambda name: name.encode("utf-8")):
        fragment = shared[filename]
        files.append({"file": filename, "source": sources[filename]})
        rules.extend((rule, f"{filename}/rules/{i}") for i, rule in enumerate(fragment.get("rules", [])))
        for i, definition in enumerate(fragment.get("rule_set", [])):
            location = f"{filename}/rule_set/{i}"
            if not isinstance(definition, dict) or not isinstance(definition.get("tag"), str) or not definition["tag"]:
                raise ValueError(f"{location}: rule_set requires a tag")
            definitions[definition["tag"]] = (definition, location)
        if "final" in fragment:
            final, final_source = fragment["final"], f"{filename}/final"
    if final not in outbounds:
        raise ValueError(f"{final_source}: expected a bound outbound: {', '.join(sorted(outbounds))}")
    sets, set_sources = {}, {}
    for tag, (definition, location) in definitions.items():
        document = rule_set_document(definition, location, config, rule_paths)
        sets[tag] = [condition(rule, f"{location}/rules/{i}", {}, headless=True)
                     for i, rule in enumerate(document["rules"])]
        set_sources[tag] = location
    compiled, provenance = [], []
    for rule, location in rules:
        result = condition(rule, location, sets)
        action = rule.get("action", "route")
        if action == "route" and rule.get("outbound") in outbounds:
            result.update(action="route", outbound=rule["outbound"])
        elif action == "reject" and "outbound" not in rule:
            result["action"] = "reject"
        else:
            raise ValueError(f"{location}: use route to a bound outbound or reject")
        compiled.append(result)
        provenance.append({"rule": location, "outbound": result.get("outbound", "reject")})
    def patterns(rule):
        return rule.get("domain_regex", []) + [re.escape(word) for word in rule.get("domain_keyword", [])] + [
            pattern for child in rule.get("rules", []) for pattern in patterns(child)]
    expressions = sorted({pattern for rule in compiled + [r for values in sets.values() for r in values] for pattern in patterns(rule)})
    regexes = {}
    if expressions:
        checked = subprocess.run([config.get("regexTool", "route-regex")], input=json.dumps(expressions),
                                 text=True, capture_output=True, timeout=30)
        if checked.returncode:
            raise ValueError("Invalid domain regular expression: " + checked.stderr.strip())
        regexes = json.loads(checked.stdout)
    route = {"rules": compiled, "rule_set": [{"type": "inline", "tag": tag, "rules": values} for tag, values in sets.items()], "final": final}
    generation = hashlib.sha256(json.dumps({"route": route, "files": files}, sort_keys=True).encode()).hexdigest()[:16]
    summary = {"generation": generation, "files": files, "rules": provenance, "rule_sets": set_sources, "final": final, "final_source": final_source}
    native, native_sources = fragments(config, "connectionFragments", connection_directory) if include_connections else ({}, {})
    duplicate = set(shared) & set(native)
    if duplicate:
        raise ValueError("route.d and connection.d share a filename: " + ", ".join(sorted(duplicate)))
    connection_rules, connection_sets, connection_files, connection_provenance = [], {}, [], []
    shared_rules = {item["rule"]: rule for item, rule in zip(provenance, compiled)}
    connection_final, connection_final_source = "proxy", "implicit final"
    for name in sorted(shared.keys() | native.keys(), key=lambda name: name.encode("utf-8")):
        is_shared = name in shared
        value = shared[name] if is_shared else native[name]
        connection_files.append({"file": name, "source": sources[name] if is_shared else native_sources[name],
                                 "consumer": "shared" if is_shared else "sing-box"})
        for index, rule in enumerate(value.get("rules", [])):
            location = f"{name}/rules/{index}"
            selected = shared_rules[location] if is_shared else rule
            connection_rules.append(selected)
            connection_provenance.append({"rule": location, "outbound": selected.get("outbound", selected.get("action", "route"))})
        for definition in value.get("rule_set", []):
            tag = definition["tag"]
            if tag in connection_sets:
                raise ValueError(f"{name}: duplicate rule_set tag {tag}")
            if is_shared:
                connection_sets[tag] = {"type": "inline", "tag": tag, "rules": sets[tag]}
            elif definition.get("type") == "remote":
                connection_sets[tag] = copy.deepcopy(definition)
            else:
                document = rule_set_document(definition, f"{name}/rule_set/{tag}", config)
                connection_sets[tag] = {"type": "inline", "tag": tag, "rules": document["rules"]}
        if "final" in value:
            connection_final, connection_final_source = value["final"], f"{name}/final"
    connection_route = {"rules": connection_rules, "rule_set": list(connection_sets.values()), "final": connection_final}
    connection_summary = {"files": connection_files, "rules": connection_provenance,
                          "final": connection_final, "final_source": connection_final_source}
    summary["connection"] = connection_summary
    summary["generation"] = hashlib.sha256(json.dumps({"dns": route, "connection": connection_route, "files": connection_files}, sort_keys=True).encode()).hexdigest()[:16]
    return {"route": route, "dns_generation": generation, "connection_route": connection_route, "sets": sets, "regexes": regexes, "summary": summary}
