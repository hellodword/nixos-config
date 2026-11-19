"""Exercise generated credentials, native proxy protocols and client artifacts."""
import argparse
import base64
import contextlib
import copy
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
import urllib.error
import urllib.parse
import urllib.request

import yaml
import dns.message
import dns.query

from tests.support import ROOT, load_script
from tests.fixtures.dns_fixture import Resolver, certificate, encrypted_server, free_port
from tests.fixtures.network_fixture import http_server, socks_server, socks_http, proxy_process

model = load_script("vps/model.py")
clients = load_script("vps/clients.py")
SERVER_SING_BOX = "sing-box"
CLIENT_SING_BOX = "sing-box"


class InventoryProtocol(unittest.TestCase):
    def inventory(self):
        return yaml.safe_load((ROOT / "data/secrets/vps.example.yaml").read_text())

    def test_mobile_direct_dns_races_and_routing(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as stack:
            root = Path(temp)
            key, cert = certificate(root)
            origin = stack.enter_context(http_server())
            resolvers, upstreams = [], []
            for branch, upstream in enumerate(clients.DIRECT_DNS):
                resolver = Resolver("cn", branch)
                resolver.ipv4 = f"127.0.0.{branch + 1}"
                port = free_port()
                stack.enter_context(encrypted_server(resolver, upstream["protocol"], key, cert,
                                                    hostname=f"resolver.test:{port}", port=port))
                resolvers.append(resolver)
                upstreams.append(upstream | {"address": "127.0.0.1", "port": port, "serverName": "resolver.test"})
            proxy_dns = Resolver("global", 0)
            proxy_dns_port = free_port()
            stack.enter_context(encrypted_server(proxy_dns, "https", key, cert,
                                                hostname=f"resolver.test:{proxy_dns_port}", port=proxy_dns_port))
            socks, calls = stack.enter_context(socks_server(proxy_dns_port, origin))
            provider = {
                "outbounds": [{"type": "socks", "tag": "fixture-path", "server": "127.0.0.1", "server_port": socks}],
                "exits": {"fixture": {"paths": ["fixture-path"]}},
                "groups": {name: {"exits": ["fixture"], "default": "fixture"} for name in ("proxy", "hideme")},
            }
            catalog = {"rule_sets": {}, "final": "hideme", "rules": [
                {"scope": "domain", "domain": "priority.race.test", "action": "route", "outbound": "proxy"},
                {"scope": "domain", "domain": "blocked.race.test", "action": "reject"},
                {"scope": "domain", "type": "logical", "mode": "or",
                 "rules": [{"domain_suffix": "race.test"}, {"domain": "direct.test"}],
                 "action": "route", "outbound": "direct"},
            ]}
            sing_box_policy = clients.purposes.sing_box
            with patch.object(clients, "DIRECT_DNS", upstreams), patch.object(
                    clients.purposes, "sing_box", side_effect=lambda groups: sing_box_policy(groups, catalog)):
                config = clients.mobile(provider)
            dns_port, socks_port = free_port(), free_port()
            config["inbounds"] = [
                {"type": "direct", "tag": "dns-test", "listen": "127.0.0.1", "listen_port": dns_port},
                {"type": "socks", "tag": "socks-test", "listen": "127.0.0.1", "listen_port": socks_port},
            ]
            config["route"]["rules"].insert(0, {"inbound": "dns-test", "action": "hijack-dns"})
            for server in config["dns"]["servers"]:
                if server["type"] == "local":
                    continue
                if not server["tag"].startswith("dns-direct-"):
                    server.update(server="127.0.0.1", server_port=proxy_dns_port,
                                  tls={"enabled": True, "server_name": "resolver.test"})
                server["tls"]["certificate_path"] = str(cert)
            config["log"]["level"] = "debug"
            (root / "network.json").write_text(json.dumps(config))

            def query(name, kind="A"):
                return dns.query.tcp(dns.message.make_query(name, kind), "127.0.0.1", port=dns_port, timeout=10)

            def race(name, request, winner=0, cached=False):
                gates = [(threading.Event(), threading.Event()) for _ in resolvers]
                for resolver, gate in zip(resolvers, gates):
                    resolver.gates[name + "."] = gate
                with ThreadPoolExecutor(max_workers=1) as executor:
                    result = executor.submit(request)
                    try:
                        for arrived, _ in gates:
                            self.assertTrue(arrived.wait(8), f"all branches received {name}")
                        if winner is not None:
                            gates[winner][1].set()
                        response = result.result(timeout=8)
                        if cached:
                            # A repeat query succeeds even while every upstream response is held.
                            gates[winner][1].clear()
                            self.assertEqual(request().answer, response.answer)
                            self.assertEqual(sum(c["name"] == name + "." for c in resolvers[winner].calls), 1)
                        return response
                    finally:
                        for _, release in gates:
                            release.set()

            with (root / "sing-box.log").open("w") as log, proxy_process(CLIENT_SING_BOX, root, log, socks_port):
                try:
                    for winner in range(len(resolvers)):
                        name = f"winner-{winner}.race.test"
                        reply = race(name, lambda: query(name), winner, cached=True)
                        self.assertEqual(reply.answer[0][0].to_text(), resolvers[winner].ipv4)
                    self.assertEqual(race("nx.race.test", lambda: query("nx.race.test")).rcode(), 3)
                    nodata = race("nodata.race.test", lambda: query("nodata.race.test"))
                    self.assertEqual((nodata.rcode(), nodata.answer), (0, []))
                    for name in ("sf.race.test", "refused.race.test"):
                        self.assertEqual(query(name).rcode(), 0)
                    self.assertEqual(query("allfail.race.test").rcode(), 2)
                    self.assertEqual(race("timeout.race.test", lambda: query("timeout.race.test"), winner=None).rcode(), 2)
                    self.assertEqual(query("types.race.test", "TXT").answer[0][0].to_text(), '"cn"')
                    self.assertEqual(query("priority.race.test").answer[0][0].to_text(), proxy_dns.ipv4)
                    self.assertEqual(query("outside.test").answer[0][0].to_text(), proxy_dns.ipv4)
                    self.assertEqual(query("blocked.race.test").rcode(), 3)
                    self.assertEqual({c["name"] for c in proxy_dns.calls}, {"priority.race.test.", "outside.test."})
                    # Only the winning DoT response leads to a listening HTTP endpoint.
                    name = "connection.race.test"
                    resolvers[-1].ipv4_by_name[name] = "127.0.0.1"
                    resolvers[0].ipv4_by_name[name] = "127.0.0.2"
                    self.assertEqual(race(name, lambda: socks_http(socks_port, name, origin), len(resolvers) - 1), "direct")
                    self.assertEqual(socks_http(socks_port, "priority.race.test", origin), "proxy")
                    self.assertEqual(calls[-1], ("priority.race.test", origin))
                except BaseException:
                    print((root / "sing-box.log").read_text(), file=sys.stderr)
                    raise

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
                    # Branch zero returns SERVFAIL for sf.* and NXDOMAIN for nx.*.
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
                    path = next(p for p in vps.provider("primary", "trojan")["outbounds"]
                                if p["tag"] == f"edge · [{name}] · Trojan")
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
                            release = threading.Event()
                            if domain.startswith("nx."):
                                resolvers[1].gates[domain + "."] = (threading.Event(), release)
                            try:
                                with self.subTest(exit=name, domain=domain), self.assertRaises((OSError, EOFError)):
                                    socks_http(port, domain, origin)
                            finally:
                                release.set()
                        for resolver in resolvers:
                            self.assertTrue(any(call["name"] == "sf.fixture.example." for call in resolver.calls))

    def test_prepared_deployments_and_native_clients(self):
        inventory = self.inventory()
        inventory["subscriptions"]["primary"]["name"] = "个人网络 (iPhone)"
        inventory["subscriptions"]["primary"]["groups"]["hideme"] = {"exits": ["west-native", "edge-native"]}
        vps = model.Inventory(inventory)

        # Diagnose a declaration before producing any deployable material.
        broken = copy.deepcopy(inventory)
        broken["exits"]["edge-native"]["options"] = {"password": {"secret": "missing-private-reference"}}
        for document, location in (
            (yaml.safe_dump(broken), "exits.edge-native.options.password.secret"),
            ("nodes: [\n  private-unfinished-value:\n", "line 3, column 1"),
        ):
            with tempfile.TemporaryDirectory() as temp:
                result = subprocess.run([sys.executable, str(ROOT / "scripts/vps/prepare.py")],
                                        input=document, text=True, cwd=temp, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn(location, result.stderr)
                self.assertNotIn("missing-private-reference", result.stderr)
                self.assertNotIn("private-unfinished-value", result.stderr)
                self.assertFalse((Path(temp) / "tmp/vps").exists())

        def check_clients(directory, mode):
            provider = json.loads((directory / "linux.json").read_text())
            title = json.loads((directory / "metadata.json").read_text())["name"]
            tags = {node["tag"] for node in provider["outbounds"]}
            self.assertEqual(len(tags), len(provider["outbounds"]))
            decoded = []
            for line in base64.b64decode((directory / "shadowrocket.txt").read_text()).decode().splitlines():
                uri = urllib.parse.urlsplit(line)
                parameters = urllib.parse.parse_qs(uri.query)
                self.assertEqual(parameters["allowInsecure" if uri.scheme == "trojan" else "insecure"], ["0"])
                decoded.append({
                    "type": uri.scheme, "tag": urllib.parse.unquote(uri.fragment),
                    "server": uri.hostname, "server_port": uri.port,
                    "password": urllib.parse.unquote(uri.username),
                    "tls": {"enabled": True, "server_name": parameters["sni"][0]},
                })
                if mode == "trojan-chain":
                    self.assertEqual(parameters["chain"], ["CHAIN"])
                    decoded[-1]["detour"] = "CHAIN"
            self.assertEqual({node["type"] for node in decoded}, {"hysteria2" if mode == "hy2" else "trojan"})
            self.assertEqual(decoded, provider["outbounds"])
            mobile = json.loads((directory / "sing-box.json").read_text())
            self.assertEqual([node for node in mobile["outbounds"] if node["tag"] in tags], decoded)
            config = directory / "sing-box.json"
            if mode == "trojan-chain":
                local = directory / "chain.json"
                local.write_text(json.dumps({"outbounds": [{"type": "socks", "tag": "CHAIN",
                                                            "server": "127.0.0.1", "server_port": 1080}]}))
                merged = directory / "merged.json"
                subprocess.run([CLIENT_SING_BOX, "merge", str(merged), "-c", str(config), "-c", str(local)], check=True)
                config = merged
            subprocess.run([CLIENT_SING_BOX, "check", "-c", str(config)], check=True)
            full = (directory / "shadowrocket.conf").read_text()
            separate = (directory / "shadowrocket-config.conf").read_text()
            proxy_section = full.partition("[Proxy]\n")[2].partition("\n[Proxy Group]")[0]
            proxies = dict(line.split(" = ", 1) for line in proxy_section.splitlines() if line)
            self.assertEqual(set(proxies), tags)
            for node in decoded:
                protocol, server, port, *options = proxies[node["tag"]].split(", ")
                self.assertEqual((protocol, server, int(port)), (node["type"], node["server"], node["server_port"]))
                options = dict(option.split("=", 1) for option in options)
                self.assertEqual(json.loads(options["password"]), node["password"])
                self.assertEqual(options["sni"], node["tls"]["server_name"])
                self.assertEqual(options["skip-cert-verify"], "false")
                self.assertEqual(options.get("chain"), node.get("detour"))
            self.assertEqual(full.partition("[Rule]\n")[2], separate.partition("[Rule]\n")[2])
            payment = next(rule for rule in mobile["route"]["rules"] if "geosite-paypal" in rule.get("rule_set", []))
            payment_dns = next(rule for rule in mobile["dns"]["rules"] if "geosite-paypal" in rule.get("rule_set", []))
            self.assertEqual((payment["outbound"], payment_dns["server"]), ("hideme", "dns-hideme"))
            self.assertTrue(any(line.endswith("/paypal.conf,hideme") for line in full.splitlines()))
            native = {n["tag"]: n for n in mobile["outbounds"] if n["type"] in {"selector", "urltest"}}
            tests = {name: set(n["outbounds"]) for name, n in native.items() if n["type"] == "urltest"}
            self.assertEqual(len(tests), len(set(map(frozenset, tests.values()))))
            for name, binding in provider["groups"].items():
                if isinstance(binding, str):
                    self.assertNotIn(name, native)
                    continue
                allowed = {p for e in binding["exits"] for p in provider["exits"][e]["paths"]}
                self.assertEqual(set(native[name]["outbounds"]) & tags, allowed)
                default = native[name]["default"]
                expected = set(provider["exits"][binding["default"]]["paths"]) if "default" in binding else allowed
                self.assertEqual(tests.get(default, {default}), expected)
            for config, embedded in ((full, True), (separate, False)):
                group_section = config.partition("[Proxy Group]\n")[2].partition("\n[Rule]")[0]
                groups = dict(line.split(" = ", 1) for line in group_section.splitlines() if line)
                self.assertEqual(set(groups), set(native))
                for name, node in native.items():
                    members = groups[name].split(", ")
                    expected = set(node["outbounds"]) & tags
                    if embedded:
                        self.assertEqual(set(members) & tags, expected)
                    else:
                        self.assertIn(title, members)
                        pattern = next(v.split("=", 1)[1] for v in members if v.startswith("policy-regex-filter="))
                        self.assertEqual({tag for tag in tags if re.fullmatch(pattern, tag)}, expected)
                    if name in tests:
                        self.assertTrue({"interval=600", "timeout=5", "tolerance=0", "hidden=1"} <= set(members))
                    else:
                        self.assertIn("policy-select-name=" + node["default"], members)

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
            for mode in model.MODES:
                with self.subTest(mode=mode):
                    check_clients(root / "subscriptions/primary" / ("" if mode == "hy2" else mode), mode)

            # Publishing an additional exit and changing subscription presentation preserve existing passwords.
            revised = copy.deepcopy(inventory)
            subscription = revised["subscriptions"].pop("primary")
            revised["subscriptions"]["personal"] = subscription
            subscription.pop("name")
            subscription["path"] = "/7ae7d48e-6d6c-4b0d-b108-72eb8c20ed7b"
            subscription["entries"].reverse()
            subscription["groups"]["proxy"]["default"] = "west-native"
            revised["exits"]["edge-extra"] = {"nodes": ["edge"], "type": "native"}
            subscription["exits"].append("edge-extra")
            with tempfile.TemporaryDirectory() as regenerated:
                subprocess.run([sys.executable, str(ROOT / "scripts/vps/prepare.py")],
                               input=yaml.safe_dump(revised), text=True, cwd=regenerated, check=True)
                updated = json.loads((Path(regenerated) / "tmp/vps/subscriptions/personal/linux.json").read_text())
                self.assertEqual(json.loads((Path(regenerated) / "tmp/vps/subscriptions/personal/metadata.json").read_text())["name"],
                                 "personal")
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
                    for mode in model.MODES:
                        directory = root / "subscriptions/primary" / ("" if mode == "hy2" else mode)
                        title = json.loads((directory / "metadata.json").read_text())["name"]
                        for client, filename in (("linux", "linux.json"), ("sing-box", "sing-box.json"),
                                                 ("shadowrocket", "shadowrocket.conf"),
                                                 ("shadowrocket-subscribe", "shadowrocket.txt"),
                                                 ("shadowrocket-config", "shadowrocket-config.conf")):
                            request = urllib.request.Request(f"{url}?client={client}&mode={mode}", headers={"User-Agent": "SFI"})
                            with urllib.request.urlopen(request, timeout=2, context=tls) as response:
                                self.assertEqual(response.read().decode(), (directory / filename).read_text())
                                if client in {"shadowrocket", "shadowrocket-config", "sing-box"}:
                                    suffix = Path(filename).suffix
                                    basename = "primary" if mode == "hy2" else f"primary-{mode}"
                                    self.assertEqual(response.headers["Content-Disposition"],
                                                     f'attachment; filename="{basename}{suffix}"; filename*=UTF-8\'\'' +
                                                     urllib.parse.quote(title + suffix, safe=""))
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
            front, front_calls = stack.enter_context(socks_server(ports["trojan"], []))
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
                if outbound.get("detour") == "CHAIN":
                    client["outbounds"].append({"type": "socks", "tag": "CHAIN", "server": "127.0.0.1", "server_port": front})
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
                providers = {name: {mode: vps.provider(name, mode) for mode in model.MODES} for name in inventory["subscriptions"]}
                with proxy_process(SERVER_SING_BOX, server_root, log, ports["trojan"]):
                    if previous:
                        # Rotating primary revokes all of its old paths; guest keeps its original subscription.
                        for mode in ("hy2", "trojan"):
                            for path in previous["primary"][mode]["outbounds"]:
                                with self.subTest(revoked=path["tag"]), self.assertRaises((OSError, EOFError)):
                                    connect(path)
                        providers["guest"] = previous["guest"]
                    for name, subscription in inventory["subscriptions"].items():
                        for exit_id in subscription["exits"]:
                            for mode, provider in providers[name].items():
                                path = next(p for p in provider["outbounds"] if p["tag"] in provider["exits"][exit_id]["paths"])
                                with self.subTest(subscription=name, path=path["tag"], rotated=previous is not None):
                                    expected = {exit_: len(requests) + (exit_ == exit_id) for exit_, requests in calls.items()}
                                    front_calls.clear()
                                    self.assertEqual(connect(path), "proxy")
                                    self.assertEqual(front_calls, [("127.0.0.1", ports["trojan"])] if mode == "trojan-chain" else [])
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
