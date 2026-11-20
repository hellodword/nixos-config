"""Network input ownership, physical egress and configuration transitions."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from tests.support import load_script

renderer = load_script("network/render.py")
underlay = load_script("network/underlay.py")
compiler = load_script("network/domain_policy.py")
lockdown = load_script("network/lockdown.py")
run_excluded = load_script("network/run_excluded.py")


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

    def test_lockdown_prepare_allows_schema_migrations_and_repairs_corrupt_seed(self):
        from unittest.mock import patch
        from types import SimpleNamespace

        fake_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE=\n"
        fake_pub = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBI=\n"

        def fake_run(args, *, data=None, check=True):
            return SimpleNamespace(returncode=0, stdout=fake_pub if "pubkey" in args else fake_key)

        with tempfile.TemporaryDirectory() as directory, patch.object(lockdown, "run", side_effect=fake_run):
            state = Path(directory) / "site-network"
            lockdown.prepare(state)
            settings_path = state / "mullvad/settings.json"
            seeded = json.loads(settings_path.read_text())
            self.assertEqual(seeded["lockdown_mode"], True)
            self.assertEqual(seeded["allow_lan"], False)

            migrated = {"settings_version": 99, "lockdown_mode": True, "allow_lan": False, "extra_field": "kept"}
            settings_path.write_text(json.dumps(migrated))
            lockdown.prepare(state)
            self.assertEqual(json.loads(settings_path.read_text()), migrated)

            settings_path.write_text("{corrupt-json")
            lockdown.prepare(state)
            self.assertEqual(json.loads(settings_path.read_text())["lockdown_mode"], True)

    def test_run_excluded_recognizes_cgroup_v1_and_v2(self):
        self.assertTrue(run_excluded.excluded("5:net_cls:/mullvad-exclusions\n0::/user.slice\n"))
        self.assertTrue(run_excluded.excluded("0::/mullvad-exclusions\n"))
        self.assertTrue(run_excluded.excluded("0::/system.slice/mullvad-exclusions\n"))
        self.assertFalse(run_excluded.excluded("0::/system.slice/sing-box.service\n"))
        self.assertFalse(run_excluded.excluded("5:net_cls:/\n0::/\n"))

    def test_underlay_watch_notifies_ready_and_coalesces_monitor_events(self):
        import os
        import signal
        import socket
        import subprocess
        import sys
        from unittest.mock import patch

        states = [
            None,
            None,
            {"interface": "eth0", "ipv4": "192.0.2.10"},
            {"interface": "eth0", "ipv4": "192.0.2.11"},
        ]
        events = []

        def fake_observe():
            return states.pop(0) if len(states) > 1 else states[0]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "underlay.json"
            notify_path = root / "notify.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as server:
                server.bind(str(notify_path))
                server.settimeout(2)

                spawns = [0]

                def spawn():
                    spawns[0] += 1
                    if spawns[0] == 1:
                        return subprocess.Popen(
                            [sys.executable, "-c", "import sys; sys.stdout.write('route1\\nroute2\\n'); sys.stdout.flush()"],
                            stdout=subprocess.PIPE,
                        )
                    os.kill(os.getpid(), signal.SIGTERM)
                    return subprocess.Popen([sys.executable, "-c", ""], stdout=subprocess.PIPE)

                with patch.dict(os.environ, {"NOTIFY_SOCKET": str(notify_path)}), \
                     patch.object(underlay, "observe", side_effect=fake_observe), \
                     patch.object(underlay, "stop_proxy", side_effect=lambda: events.append("stop")), \
                     patch.object(underlay, "start_proxy", side_effect=lambda: events.append("start")), \
                     patch.object(underlay.time, "sleep", side_effect=lambda _: None):
                    underlay.watch(output, spawn_monitor=spawn)
                self.assertEqual(server.recv(64), b"READY=1")
            self.assertEqual(json.loads(output.read_text()), {"interface": "eth0", "ipv4": "192.0.2.11"})
            self.assertEqual(events, ["stop", "start", "stop", "start"])
