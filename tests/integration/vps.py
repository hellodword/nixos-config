"""Exercise generated credentials, native proxy protocols and client artifacts."""
import argparse
import contextlib
import copy
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

import yaml

from tests.support import ROOT, load_script
from tests.fixtures.dns_fixture import Resolver, certificate, encrypted_server, free_port
from tests.fixtures.network_fixture import http_server, socks_server, socks_http
from tests.integration.network import proxy_process

model = load_script("vps/model.py")
clients = load_script("vps/clients.py")
SERVER_SING_BOX = "sing-box"
CLIENT_SING_BOX = "sing-box"


class InventoryProtocol(unittest.TestCase):
    def inventory(self):
        return yaml.safe_load((ROOT / "data/secrets/vps.example.yaml").read_text())

    def test_exit_dns_races_and_cache(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            root = Path(temp)
            key, cert = certificate(root)
            origin = stack.enter_context(http_server())
            inventory = self.inventory()
            inventory["exits"] = {}
            observations = {}
            for name, group in (("first", "cn"), ("second", "global")):
                resolvers, ports = [], []
                for branch in range(2):
                    resolver = Resolver(group, branch)
                    # The first resolver wins ordinary queries, but returns SERVFAIL for sf.*.
                    port = free_port()
                    stack.enter_context(encrypted_server(resolver, "https", key, cert,
                                                        hostname=f"resolver.test:{port}", port=port))
                    resolvers.append(resolver)
                    ports.append(port)
                socks, calls = stack.enter_context(socks_server(ports, origin))
                inventory["exits"][name] = {
                    "nodes": ["edge"], "type": "socks",
                    "options": {"server": "127.0.0.1", "server_port": socks},
                    "dns": [{"type": "https", "server": "127.0.0.1", "server_port": port,
                             "path": "/dns-query", "tls": {"enabled": True, "server_name": "resolver.test",
                                                            "certificate_path": str(cert)}} for port in ports],
                }
                observations[name] = (resolvers, calls)
            inventory["subscriptions"] = {"primary": inventory["subscriptions"]["primary"] | {
                "entries": ["edge"], "exits": ["first", "second"],
                "groups": {"proxy": {"exits": ["first", "second"], "default": "first"}},
            }}
            vps = model.Inventory(inventory)
            server = vps.server("edge")
            ports = {protocol: free_port() for protocol in ("trojan", "hysteria2")}
            for inbound in server["inbounds"]:
                inbound.update(listen="127.0.0.1", listen_port=ports[inbound["type"]],
                               tls={"enabled": True, "certificate_path": str(cert), "key_path": str(key)})
            (root / "network.json").write_text(json.dumps(server))
            with (root / "sing-box.log").open("w") as log, proxy_process(SERVER_SING_BOX, root, log, ports["trojan"]):
                for name, (resolvers, calls) in observations.items():
                    path = next(p for p in vps.provider("primary")["outbounds"]
                                if p["tag"] == f"path-edge-edge-{name}-trojan")
                    path.update(server="127.0.0.1", server_port=ports["trojan"],
                                tls={"enabled": True, "server_name": "resolver.test", "certificate_path": str(cert)})
                    client = root / name
                    client.mkdir()
                    port = free_port()
                    (client / "network.json").write_text(json.dumps({
                        "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": port}], "outbounds": [path]}))
                    with (client / "sing-box.log").open("w") as client_log, proxy_process(CLIENT_SING_BOX, client, client_log, port):
                        for domain in ("cached.fixture.example", "sf.fixture.example"):
                            self.assertEqual(socks_http(port, domain, origin), "proxy", (root / "sing-box.log").read_text())
                            self.assertEqual(calls[-1], (resolvers[0].ipv4, origin))
                        counts = [len(resolver.calls) for resolver in resolvers]
                        self.assertEqual(socks_http(port, "cached.fixture.example", origin), "proxy")
                        self.assertEqual([len(resolver.calls) for resolver in resolvers], counts)
                        for domain in ("nx.fixture.example", "allfail.fixture.example"):
                            with self.subTest(exit=name, domain=domain), self.assertRaises((OSError, EOFError)):
                                socks_http(port, domain, origin)
                        for resolver in resolvers:
                            self.assertTrue(any(call["name"] == "sf.fixture.example." for call in resolver.calls))

    def test_prepared_deployments_and_native_clients(self):
        inventory = self.inventory()
        vps = model.Inventory(inventory)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "tmp/vps"
            subprocess.run([sys.executable, str(ROOT / "scripts/vps/prepare.py")],
                           input=yaml.safe_dump(inventory), text=True, cwd=temp, check=True)
            metadata = json.loads((root / "metadata.json").read_text())
            provider = json.loads((root / "subscriptions/primary/linux.json").read_text())
            for artifact in root.rglob("*"):
                if artifact.is_file():
                    self.assertNotIn(inventory["subscriptions"]["primary"]["key"], artifact.read_text())
            for value in [*vps.secrets.values(), *(path["password"] for path in provider["outbounds"])]:
                self.assertNotIn(value, (root / "metadata.json").read_text())
            for name in vps.nodes:
                release = metadata["nodes"][name]["release"]
                server = root / "nodes" / name / release / "proxy.json"
                self.assertEqual(server.stat().st_mode & 0o777, 0o600)
                other = "west" if name == "edge" else "edge"
                for protocol in ("trojan", "hysteria2"):
                    self.assertNotIn(vps.password("primary", f"{other}-native", protocol), server.read_text())
            mobile_path = root / "subscriptions/primary/sing-box.json"
            selectors = {node["tag"]: node for node in json.loads(mobile_path.read_text())["outbounds"]
                         if node["type"] == "selector"}
            self.assertEqual(selectors["ai"]["default"], "exit-west-native")
            self.assertEqual(selectors["proxy"]["default"], "exit-edge-native")
            subprocess.run([CLIENT_SING_BOX, "check", "-c", str(mobile_path)], check=True)

            # Publishing an additional exit and changing subscription presentation preserve existing passwords.
            revised = copy.deepcopy(inventory)
            subscription = revised["subscriptions"].pop("primary")
            revised["subscriptions"]["personal"] = subscription
            subscription["path"] = "/7ae7d48e-6d6c-4b0d-b108-72eb8c20ed7b"
            subscription["entries"].reverse()
            subscription["groups"]["proxy"]["default"] = "west-native"
            revised["exits"]["edge-extra"] = {"nodes": ["edge"], "type": "native"}
            subscription["exits"].append("edge-extra")
            with tempfile.TemporaryDirectory() as regenerated:
                subprocess.run([sys.executable, str(ROOT / "scripts/vps/prepare.py")],
                               input=yaml.safe_dump(revised), text=True, cwd=regenerated, check=True)
                updated = json.loads((Path(regenerated) / "tmp/vps/subscriptions/personal/linux.json").read_text())
                passwords = {path["tag"]: path["password"] for path in updated["outbounds"]}
                for path in provider["outbounds"]:
                    self.assertEqual(passwords[path["tag"]], path["password"])

            # Exercise the certificate Worker's upstream boundary with generated bindings.
            subprocess.run(["node", "--test", str(ROOT / "tests/integration/vps-workers.mjs")],
                           env=os.environ | {"VPS_DIRECTORY": str(root)}, check=True)
            port = free_port()
            key, cert = root / "https.key", root / "https.crt"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(cert), "-days", "1",
                            "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tls = ssl.create_default_context(cafile=str(cert))
            with (root / "wrangler.log").open("w") as log:
                process = subprocess.Popen(["wrangler", "dev", "--local", "--ip", "127.0.0.1", "--port", str(port),
                                            "--local-protocol=https", "--https-key-path", str(key), "--https-cert-path", str(cert),
                                            "--inspector-port", "0", "--show-interactive-dev-session=false"],
                                           cwd=root / "workers/subscriptions", stdout=log, stderr=log,
                                           env=os.environ | {"CI": "true", "WRANGLER_SEND_METRICS": "false", "HOME": temp})
                try:
                    route = "/68097ddf-1b6a-4847-a754-c29194e6f69c"
                    url = f"https://127.0.0.1:{port}{route}" + vps.subscriptions["primary"]["path"]
                    request = urllib.request.Request(url + "?client=linux", headers={"User-Agent": "Shadowrocket/2.2"})
                    deadline = time.monotonic() + 30
                    while True:
                        self.assertIsNone(process.poll(), (root / "wrangler.log").read_text())
                        try:
                            with urllib.request.urlopen(request, timeout=2, context=tls) as response:
                                self.assertEqual(json.load(response), vps.provider("primary"))
                                self.assertEqual(response.headers["Cache-Control"], "private, no-store")
                            break
                        except urllib.error.HTTPError:
                            self.fail((root / "wrangler.log").read_text())
                        except OSError:
                            if time.monotonic() > deadline:
                                self.fail((root / "wrangler.log").read_text())
                            time.sleep(0.1)
                    for agent, filename in (
                        ("SFA (sing-box 1.14; language en_US)", "sing-box.json"),
                        ("SFI (sing-box 1.14; language en_US)", "sing-box.json"),
                        ("Shadowrocket/2.2", "shadowrocket.conf"),
                    ):
                        with self.subTest(agent=agent):
                            request = urllib.request.Request(url, headers={"User-Agent": agent})
                            with urllib.request.urlopen(request, timeout=2, context=tls) as response:
                                self.assertEqual(response.read().decode(), (root / "subscriptions/primary" / filename).read_text())
                    # The static-asset binding is reachable only through the subscription handler.
                    with self.assertRaises(urllib.error.HTTPError) as denied:
                        urllib.request.urlopen(url + "/linux.json", timeout=2, context=tls)
                    self.assertEqual(denied.exception.code, 404)
                    denied.exception.close()
                finally:
                    process.terminate()
                    process.wait(timeout=10)

    def test_authenticated_trojan_and_hysteria2(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            root = Path(temp)
            key, cert = certificate(root)
            origin = stack.enter_context(http_server())
            inventory = self.inventory()
            calls = {}
            for exit_id in ("edge-native", "edge-socks"):
                socks, calls[exit_id] = stack.enter_context(socks_server([], origin))
                inventory["exits"][exit_id] = {"nodes": ["edge"], "type": "socks",
                                               "options": {"server": "127.0.0.1", "server_port": socks}}
            primary = inventory["subscriptions"]["primary"]
            primary["entries"] = ["edge"]
            primary["exits"] = list(calls)
            primary["groups"] = {"proxy": {"exits": list(calls), "default": "edge-native"}}
            inventory["subscriptions"]["guest"] = {
                "path": "/7ae7d48e-6d6c-4b0d-b108-72eb8c20ed7b", "key": "b6" * 32,
                "entries": ["edge"], "exits": ["edge-socks"], "groups": {"proxy": {"exits": ["edge-socks"]}},
            }
            ports = {protocol: free_port() for protocol in ("trojan", "hysteria2")}
            server_root = root / "server"
            server_root.mkdir()
            log = stack.enter_context((server_root / "sing-box.log").open("w"))

            def connect(path):
                client_root = root / "client"
                client_root.mkdir(exist_ok=True)
                mixed = free_port()
                outbound = copy.deepcopy(path)
                outbound.update(server="127.0.0.1", server_port=ports[path["type"]],
                                tls={"enabled": True, "server_name": "resolver.test", "certificate_path": str(cert)})
                client = {"inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": mixed}],
                          "outbounds": [outbound]}
                (client_root / "network.json").write_text(json.dumps(client))
                with (client_root / "sing-box.log").open("w") as client_log, proxy_process(CLIENT_SING_BOX, client_root, client_log, mixed):
                    return socks_http(mixed, "198.51.100.1", origin)

            previous = None
            for subscription_key in (primary["key"], "a5" * 32):
                primary["key"] = subscription_key
                vps = model.Inventory(inventory)
                server = vps.server("edge")
                for inbound in server["inbounds"]:
                    inbound.update(listen="127.0.0.1", listen_port=ports[inbound["type"]],
                                   tls={"enabled": True, "certificate_path": str(cert), "key_path": str(key)})
                (server_root / "network.json").write_text(json.dumps(server))
                providers = {name: vps.provider(name) for name in inventory["subscriptions"]}
                with proxy_process(SERVER_SING_BOX, server_root, log, ports["trojan"]):
                    if previous:
                        # Rotating primary revokes all of its old paths; guest keeps its original subscription.
                        for path in previous["primary"]["outbounds"]:
                            with self.subTest(revoked=path["tag"]), self.assertRaises((OSError, EOFError)):
                                connect(path)
                        providers["guest"] = previous["guest"]
                    for name, subscription in inventory["subscriptions"].items():
                        for exit_id in subscription["exits"]:
                            for protocol in ports:
                                tag = f"path-edge-edge-{exit_id}-{protocol}"
                                path = next(p for p in providers[name]["outbounds"] if p["tag"] == tag)
                                with self.subTest(subscription=name, path=tag, rotated=previous is not None):
                                    expected = {exit_: len(requests) + (exit_ == exit_id) for exit_, requests in calls.items()}
                                    self.assertEqual(connect(path), "proxy")
                                    self.assertEqual({exit_: len(requests) for exit_, requests in calls.items()}, expected)
                                    self.assertEqual(calls[exit_id][-1], ("198.51.100.1", origin))
                previous = providers


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-sing-box", default=SERVER_SING_BOX)
    parser.add_argument("--client-sing-box", default=CLIENT_SING_BOX)
    args, remaining = parser.parse_known_args()
    SERVER_SING_BOX, CLIENT_SING_BOX = args.server_sing_box, args.client_sing_box
    unittest.main(argv=[sys.argv[0], *remaining])
