"""Insert authorized paths into the native client configuration and rule catalog."""
import copy
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "network"))
from render import grouped_outbounds
import purposes

DATA = Path(__file__).resolve().parents[2] / "data/network"


def mobile(provider):
    config = json.loads((DATA / "sing-box-client.json").read_text())
    prototype = next(server for server in config["dns"]["servers"] if server["tag"] == "dns-proxy")
    for name in provider["groups"]:
        if name != "proxy":
            config["dns"]["servers"].append(copy.deepcopy(prototype) | {"tag": "dns-" + name, "detour": name})
    route, dns = purposes.sing_box(provider["groups"])
    config["route"]["rule_set"] = route["rule_set"]
    config["route"]["rules"].extend(route["rules"])
    config["route"]["final"] = route["final"]
    config["dns"]["rules"].extend(dns["rules"])
    config["dns"]["final"] = dns["final"]
    config["outbounds"].extend(grouped_outbounds(provider))
    config["outbounds"].extend(copy.deepcopy(provider["outbounds"]))
    return config


def shadowrocket(provider):
    general, _, rules = (DATA / "shadowrocket-client.conf").read_text().partition("[Rule]\n")
    lines = [general.rstrip(), "", "[Proxy]"]
    for node in provider["outbounds"]:
        lines.append(f"{node['tag']} = {node['type']}, {node['server']}, {node['server_port']}, "
                     f"password={json.dumps(node['password'])}, sni={node['tls']['server_name']}, "
                     "skip-cert-verify=false, udp-relay=true")
    lines += ["", "[Proxy Group]"]
    for name, exit_ in provider["exits"].items():
        lines.append(f"exit-{name}-auto = url-test, " + ", ".join(exit_["paths"]) +
                     ", url=https://www.gstatic.com/generate_204, interval=180, tolerance=100")
        lines.append(f"exit-{name} = select, exit-{name}-auto, " + ", ".join(exit_["paths"]))
    for name, binding in provider["groups"].items():
        choices = [binding["default"], *(e for e in binding["exits"] if e != binding["default"])]
        lines.append(f"{name} = select, " + ", ".join("exit-" + e for e in choices))
    lines += ["", "[Rule]", rules.rstrip()]
    lines.extend(purposes.shadowrocket(provider["groups"]))
    return "\n".join([*lines, ""])
