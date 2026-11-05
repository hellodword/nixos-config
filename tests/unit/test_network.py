"""Network input ownership, physical egress and configuration transitions."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from tests.support import load_script

renderer = load_script("network/render.py")
underlay = load_script("network/underlay.py")
compiler = load_script("network/domain_policy.py")
runtime = load_script("network/runtime_policy.py")


class NetworkConfiguration(unittest.TestCase):
    def test_provider_supplies_nodes_while_system_owns_routing(self):
        base = {"outbounds": [{"type": "direct", "tag": "direct"}, {"type": "urltest", "tag": "auto"}],
                "route": {"final": "auto"}}
        original = copy.deepcopy(base)
        nodes = [{"type": "socks", "tag": "first"}, {"type": "http", "tag": "second"}]
        result = renderer.combine(base, {"outbounds": nodes})
        self.assertEqual(result["outbounds"][1]["outbounds"], ["first", "second"])
        self.assertEqual(result["outbounds"][2:], nodes)
        self.assertEqual(result["route"], original["route"])
        for provider in ({"outbounds": nodes, "route": {}}, {"outbounds": []},
                         {"outbounds": [{"type": "direct", "tag": "fallback"}]},
                         {"outbounds": [{"type": "socks", "tag": "direct"}]},
                         {"outbounds": [nodes[0], nodes[0]]}):
            with self.subTest(provider=provider), self.assertRaises(ValueError):
                renderer.combine(base, provider)
        endpoint = {"type": "wireguard", "tag": "wireguard-node"}
        endpoints = renderer.combine(base, {"endpoints": [endpoint]})
        self.assertEqual(endpoints["outbounds"][1]["outbounds"], ["wireguard-node"])
        self.assertEqual(endpoints["endpoints"], [endpoint])
        self.assertEqual(base, original)

    def test_physical_egress_tracks_connection_and_address_changes(self):
        links = [{"ifname": n, "flags": ["UP"], "operstate": "UP"} for n in ("wlan0", "wg0-mullvad", "tailscale0")]
        routes = [{"dst": "default", "dev": n, "metric": m} for n, m in (("wg0-mullvad", 0), ("wlan0", 100))]
        addresses = [{"ifname": "wlan0", "addr_info": [{"scope": "global", "local": "192.0.2.2"}]}]
        for address in ("192.0.2.2", "192.0.2.3"):
            addresses[0]["addr_info"][0]["local"] = address
            selected = underlay.select(routes, links, addresses, {"wlan0"})
            config = {"outbounds": [{"type": "direct", "tag": "direct"}]}
            renderer.bind_underlay(config, selected)
            self.assertEqual(config["outbounds"][0]["bind_interface"], "wlan0")
            self.assertEqual(config["outbounds"][0]["inet4_bind_address"], address)
        self.assertIsNone(underlay.select(routes[:1], links, addresses, {"wlan0"}))
        for selected in (None, {"interface": "wlan0"}):
            with self.assertRaises(ValueError):
                renderer.bind_underlay({"outbounds": []}, selected)

    def test_route_directory_replacement_and_ruleset_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ruleset = root / "domains.json"
            ruleset.write_text(json.dumps({"version": 3, "rules": [{"domain_suffix": "example.com"}]}))
            fragments = root / "route.d"
            fragments.mkdir()
            policy = {"routeFragments": {
                "00-defaults.json": {"final": "proxy"},
                "20-private.json": {"rules": [{"domain_suffix": "home.arpa", "outbound": "private"}]},
                "80-rules.json": {"rule_set": [{"type": "local", "tag": "local", "path": str(ruleset)}],
                                  "rules": [{"rule_set": "local", "outbound": "direct"}]},
            }}
            (fragments / "05-first.json").write_text(json.dumps({"rules": [{"domain": "host.home.arpa", "outbound": "direct"}]}))
            (fragments / "20-private.json").write_text('{"rules": []}')
            (fragments / "99-final.json").write_text('{"final": "direct"}')
            connections = root / "connection.d"
            connections.mkdir()
            (connections / "03-ip.jsonc").write_text('{ // TCP policy\n "rules": [{"ip_cidr": "198.18.0.0/15", "port": 443, "outbound": "node-a"},], }')
            (connections / "98-final.jsonc").write_text('{"final": "node-a"}')
            model = compiler.compile_policy(policy, fragments, connections)
            self.assertEqual([r["outbound"] for r in model["connection_route"]["rules"]], ["node-a", "direct", "direct"])
            self.assertEqual(model["connection_route"]["final"], "direct")
            (connections / "98-final.jsonc").rename(connections / "99-z-final.jsonc")
            self.assertEqual(compiler.compile_policy(policy, fragments, connections)["connection_route"]["final"], "node-a")
            self.assertEqual([r["outbound"] for r in model["route"]["rules"]], ["direct", "direct"])
            self.assertEqual(model["route"]["final"], "direct")
            self.assertEqual([f["file"] for f in model["summary"]["files"]],
                             ["00-defaults.json", "05-first.json", "20-private.json", "80-rules.json", "99-final.json"])
            self.assertEqual(model["summary"]["rules"][0]["rule"], "05-first.json/rules/0")
            ruleset.write_text(json.dumps({"version": 3, "rules": [{"domain": "changed.example"}]}))
            self.assertEqual(model["route"]["rule_set"][0]["rules"], [{"domain_suffix": ["example.com"]}])
            changed = compiler.compile_policy(policy, fragments, connections)
            self.assertEqual(changed["route"]["rule_set"][0]["rules"], [{"domain": ["changed.example"]}])
            self.assertNotEqual(model["dns_generation"], changed["dns_generation"])

    def test_apply_failure_rolls_back_and_can_be_retried(self):
        for initial in ("active", "failed", "activating"):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                old, new = root / "generation-old", root / "generation-new"
                old.mkdir()
                new.mkdir()
                runtime.publish(root, old)
                services = list(runtime.SERVICE_FILES)
                manifests = {unit: {name: "same" for name in files} for unit, files in runtime.SERVICE_FILES.items()}
                (old / "activation.json").write_text(json.dumps(manifests))
                manifests["sing-box.service"]["provider.json"] = "new-node"
                (new / "activation.json").write_text(json.dumps(manifests))
                # An intentionally stopped DNS worker remains stopped. All
                # running DNS workers keep serving during a node-only update.
                inactive = services[-1]
                running = set(services[:-1]) | {runtime.WATCHER}
                pending = {}
                if initial != "active":
                    running.remove("sing-box.service")
                    pending["sing-box.service"] = initial
                protected = {"mullvad-daemon.service", "site-network-routing.service"}
                running |= protected
                fail_once = True

                def run(command, action, *arguments, check=True):
                    nonlocal fail_once
                    if action == "show":
                        unit = arguments[-1]
                        state = pending.get(unit, "active" if unit in running else "inactive")
                        return subprocess.CompletedProcess(arguments, 0, stdout=(state + "\n").encode())
                    units = set(arguments) - {"--quiet"}
                    if action == "is-active":
                        return subprocess.CompletedProcess(arguments, 0 if units <= running else 3)
                    self.assertTrue(units <= {"sing-box.service", runtime.WATCHER}, "unchanged DNS keeps serving")
                    if action == "stop":
                        if units & set(services):
                            self.assertNotIn(runtime.WATCHER, running)
                        running.difference_update(units)
                    elif action == "start":
                        if fail_once and units & set(services):
                            self.assertEqual((root / "current").resolve(), new)
                            fail_once = False
                            raise subprocess.CalledProcessError(1, arguments)
                        running.update(units)
                    for unit in units:
                        pending.pop(unit, None)
                    self.assertTrue(protected <= running)
                    return subprocess.CompletedProcess(arguments, 0)

                expected = (set(services) - {inactive}) | {runtime.WATCHER} | protected
                with self.assertRaises(subprocess.CalledProcessError):
                    runtime.activate(root, new, True, run, lambda *_: None)
                self.assertEqual((root / "current").resolve(), old)
                self.assertEqual(running, expected)
                self.assertEqual(runtime.activate(root, new, True, run, lambda *_: None), old)
                self.assertEqual((root / "current").resolve(), new)
                self.assertEqual(running, expected)


if __name__ == "__main__":
    unittest.main()
