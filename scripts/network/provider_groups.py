"""Client purpose selection and URL tests shared by subscription formats."""


def purpose_group(name, groups):
    name = name if name in groups else "proxy"
    target = groups.get(name)
    if isinstance(target, str):
        if not isinstance(groups.get(target), dict):
            raise ValueError(f"group {name} must reference a directly defined purpose")
        return target
    return name


def apply_selections(groups, selections):
    chosen = {}
    for name, exit_id in selections.items():
        if name not in groups:
            raise ValueError(f"unknown purpose in selections.json: {name}")
        target = purpose_group(name, groups)
        if exit_id not in groups[target]["exits"]:
            raise ValueError(f"selected exit is not authorized for {name}")
        if target in chosen and chosen[target][1] != exit_id:
            raise ValueError(f"conflicting selections for {chosen[target][0]} and {name}; use {target} in selections.json")
        chosen[target] = (name, exit_id)
    for target, (_, exit_id) in chosen.items():
        groups[target] = {"exits": [exit_id], "default": exit_id}


def grouped_outbounds(provider, reserved=()):
    groups, exits = provider["groups"], provider["exits"]
    paths = {node["tag"] for node in provider.get("outbounds", []) + provider.get("endpoints", [])}
    reserved = paths | set(reserved) | {"direct", "private", "tailnet", "local", "auto", "transparent", "CHAIN"}
    if "proxy" not in groups or reserved.intersection(groups):
        raise ValueError("grouped providers require a proxy purpose and distinct group names")
    for name, exit_ in exits.items():
        if not exit_["paths"] or not paths.issuperset(exit_["paths"]):
            raise ValueError(f"exit {name} must reference concrete provider nodes")
    tests, selectors = {}, []

    def automatic(exit_ids):
        members = list(dict.fromkeys(path for e in exit_ids for path in exits[e]["paths"]))
        if len(members) == 1:
            return members[0], members
        key = frozenset(members)
        if key not in tests:
            tag = "自动 · " + " + ".join(sorted(exit_ids))
            if tag in reserved or tag in groups:
                raise ValueError("automatic group conflicts with an outbound")
            tests[key] = {"type": "urltest", "tag": tag, "outbounds": members,
                          "url": "https://www.gstatic.com/generate_204", "interval": "3m",
                          "tolerance": 100, "interrupt_exist_connections": False}
        return tests[key]["tag"], members

    for name, binding in groups.items():
        if name != purpose_group(name, groups):
            continue
        choices = list(dict.fromkeys(binding["exits"]))
        if not choices or not set(choices) <= exits.keys():
            raise ValueError("purpose groups require authorized exits")
        auto, members = automatic(choices)
        preferred = binding.get("default")
        if preferred is not None and preferred not in choices:
            raise ValueError("default exit must belong to the purpose")
        initial = automatic([preferred])[0] if preferred is not None else auto
        selectors.append({"type": "selector", "tag": name, "default": initial,
                          "outbounds": list(dict.fromkeys([initial, auto, *members])),
                          "interrupt_exist_connections": False})
    return [*tests.values(), *selectors]
