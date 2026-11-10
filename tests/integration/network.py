#!/usr/bin/env python3
"""Real resolver races through the shipped proxy, with observable egress paths."""
import argparse
import contextlib
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

from tests.fixtures.dns_fixture import Resolver, certificate, encrypted_server, free_port
from tests.fixtures.network_fixture import http_server, socks_server, socks_http, serve


from tests.support import load_script
from tests.integration import dns as dns_test

compiler = load_script("network/dns_policy.py")
assembler = load_script("network/assemble.py")
renderer = load_script("network/render.py")


@contextlib.contextmanager
def proxy_process(executable, root, log, port):
    process = subprocess.Popen([executable, "run", "-D", str(root), "-c", str(root / "network.json")], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 10
        while True:
            assert process.poll() is None, (root / "sing-box.log").read_text()
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                assert time.monotonic() < deadline, "proxy listener did not become ready"
                time.sleep(0.05)
        yield
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def remote_ip_rules(executable, root):
    """Native rule updates change egress in place and survive offline restart."""
    root.mkdir()
    published = root / "published"
    published.mkdir()
    initial = root / "initial.srs"
    def compile_to(path, cidr):
        source = root / "rules.json"
        source.write_text(json.dumps({"version": 3, "rules": [{"ip_cidr": cidr}]}))
        subprocess.run([executable, "rule-set", "compile", str(source), "-o", str(path)], check=True)
    compile_to(initial, "127.0.0.1/32")
    (published / "ips.srs").write_bytes(initial.read_bytes())
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=published))
    download_port = server.server_address[1]
    mixed = free_port()
    with http_server() as origin, socks_server([download_port], origin) as (proxy, calls), \
            (root / "sing-box.log").open("w") as log:
        policy = {"connectionFragments": {"10-ips.json": {
            "rules": [{"rule_set": "remote-ips", "outbound": "direct"}],
            "rule_set": [{"type": "remote", "tag": "remote-ips", "format": "binary",
                          "url": f"http://127.0.0.1:{download_port}/ips.srs", "initial_path": str(initial),
                          "update_interval": "1s", "http_client": {"detour": "proxy"}}]}}}
        config = {"inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": mixed}],
                  "outbounds": [{"type": "direct", "tag": "direct"},
                                {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": proxy}],
                  "route": assembler.domain_policy.compile_policy(policy)["connection_route"],
                  "experimental": {"cache_file": {"enabled": True, "path": str(root / "cache.db")}}}
        (root / "network.json").write_text(json.dumps(config))
        with serve(server), proxy_process(executable, root, log, mixed):
            assert socks_http(mixed, "127.0.0.1", origin) == "direct"
            compile_to(published / "ips.srs", "192.0.2.0/24")
            deadline = time.monotonic() + 15
            while socks_http(mixed, "127.0.0.1", origin) != "proxy":
                assert time.monotonic() < deadline, (root / "sing-box.log").read_text()
                time.sleep(0.1)
            assert ("127.0.0.1", download_port) in calls
        with proxy_process(executable, root, log, mixed):
            assert socks_http(mixed, "127.0.0.1", origin) == "proxy"


def main():
    parser = argparse.ArgumentParser()
    for arg in ("sing-box", "template", "dnsdist", "dnsproxy", "dnscollector", "collector-template"):
        parser.add_argument("--" + arg, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="network-contract-") as directory, contextlib.ExitStack() as stack:
        root = Path(directory)
        key, cert = certificate(root)
        groups, resolvers, global_ports = {}, {}, []
        for group in ("cn", "global"):
            groups[group], resolvers[group] = {"upstreams": []}, []
            for branch, protocol in enumerate(("tls", "https")):
                resolver = Resolver(group, branch)
                resolver.ipv4, resolver.ipv6 = "127.0.0.1", "::1"
                resolvers[group].append(resolver)
                port = stack.enter_context(encrypted_server(resolver, protocol, key, cert))
                groups[group]["upstreams"].append({"protocol": protocol, "address": "127.0.0.1", "port": port, "serverName": "resolver.test"})
                if group == "global":
                    global_ports.append(port)
        origin = stack.enter_context(http_server())
        stack.enter_context(http_server("::1", origin))
        proxy_context = socks_server(global_ports, origin)
        proxy, proxy_calls = proxy_context.__enter__()
        stack.callback(proxy_context.__exit__, None, None, None)
        front, bootstrap, mixed = free_port(), free_port(), free_port()
        policy = {"groups": groups, "tunnelGroups": ["global"], "caStore": str(cert),
                  "frontPort": front, "bootstrapPort": bootstrap,
                  "legPortBase": 16400, "racePortBase": 16500, "tunnelPortBase": 16600,
                  "routeFragments": {
                    "00-defaults.json": {"final": "proxy"},
                    "20-private.json": {"rules": [{"domain_suffix": ["home.arpa", "ts.net"], "outbound": "private"}]},
                    "40-route.json": {"rules": [
                      {"domain_regex": r"^UPPER\.test$", "outbound": "direct"},
                      {"domain_regex": r"(?i)^mixed\.test$", "outbound": "direct"},
                      {"domain": "special.example.test", "outbound": "proxy"},
                      {"domain": "api.other.test", "outbound": "direct"},
                      {"domain_regex": r"foo-\d+\.test", "outbound": "direct"},
                      {"type": "logical", "mode": "and", "rules": [
                        {"rule_set": "local-domains"}, {"domain_keyword": "excluded", "invert": True}
                      ], "outbound": "direct"},
                      {"domain_suffix": ["direct.test", "example.test"], "outbound": "direct"},
                      {"domain_suffix": "blocked.test", "action": "reject"},
                    ], "rule_set": [{"type": "inline", "tag": "local-domains", "rules": [
                        {"domain_suffix": ".ruleset.test"},
                        {"type": "logical", "mode": "or", "rules": [{"domain": "logical.test"}, {"domain_regex": "unanchored"}]}
                    ]}]}
                  }}
        connections = root / "connection.d"
        connections.mkdir()
        addresses = root / "addresses.jsonc"
        addresses.write_text('// local IP ranges\n{"version":3,"rules":[{"ip_cidr":["127.0.0.1/32"]},],}')
        # This earlier connection rule changes TCP routing while DNS keeps its
        # shared direct.test classification. Input files retain comments.
        (connections / "30-connection.jsonc").write_text(
            '{ // local transport policy\n "rules": ['
            '{"domain":"connection.direct.test", "port":' + str(origin) + ', "network":"tcp", "outbound":"fixture"},'
            '{"rule_set":"local-ips", "port":' + str(origin) + ', "outbound":"fixture"},],'
            '"rule_set":[{"type":"local","tag":"local-ips","path":' + json.dumps(str(addresses)) + '},], }')
        model = assembler.domain_policy.compile_policy(policy, connection_directory=connections)
        compiler.compile_policy(policy, root / "dns", model)
        templates = json.loads(Path(args.template).read_text())
        base = templates["combined"]
        for server in base["dns"]["servers"]:
            server["server_port"] = front if server["tag"] == "dns-policy" else bootstrap
        for inbound in base["inbounds"]:
            inbound["listen_port"] = mixed
        config = assembler.assemble(base, policy, json.loads((root / "dns/transports.json").read_text()), model)
        api_port = free_port()
        config["experimental"]["clash_api"] = {"external_controller": f"127.0.0.1:{api_port}", "secret": "synthetic-api-token"}
        def api(method="GET", data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{api_port}/proxies/proxy", method=method,
                headers={"Authorization": "Bearer synthetic-api-token", "Content-Type": "application/json"},
                data=json.dumps(data).encode() if data is not None else None)
            with urllib.request.urlopen(request, timeout=5) as response:
                body = response.read()
                return json.loads(body) if body else None
        template = root / "template.json"
        provider = root / "provider.json"
        output = root / "network.json"
        template.write_text(json.dumps(config))
        node = {"type": "socks", "tag": "fixture", "server": "proxy-node.example", "server_port": proxy,
                "domain_resolver": {"server": "dns-bootstrap", "strategy": "ipv4_only"}}
        provider.write_text("// proxy credentials\n" + json.dumps({"outbounds": [node]}))
        renderer.render(template, provider, output, args.sing_box)
        validated = output.read_bytes()
        # Exercise the real validator and atomic publication before starting
        # the resolver/proxy stack with the last accepted configuration.
        provider.write_text(json.dumps({"outbounds": [node | {"server_port": "invalid-port"}]}))
        try:
            renderer.render(template, provider, output, args.sing_box)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid provider was published")
        assert output.read_bytes() == validated, "failed validation replaced the active configuration"
        provider.write_text("// proxy credentials\n" + json.dumps({"outbounds": [node]}))
        renderer.render(template, provider, output, args.sing_box)
        log = stack.enter_context((root / "sing-box.log").open("w"))
        process = subprocess.Popen([args.sing_box, "run", "-D", str(root), "-c", str(output)], stdout=log, stderr=log)
        try:
            for _ in range(100):
                assert process.poll() is None, (root / "sing-box.log").read_text()
                try:
                    with socket.create_connection(("127.0.0.1", mixed), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            assertions = 0
            with dns_test.processes(args, policy, root / "dns"):
                assert "fixture" in api()["all"]
                api("PUT", {"name": "fixture"})
                process.terminate()
                process.wait(timeout=5)
                process = subprocess.Popen([args.sing_box, "run", "-D", str(root), "-c", str(output)], stdout=log, stderr=log)
                for _ in range(100):
                    assert process.poll() is None, (root / "sing-box.log").read_text()
                    try:
                        if api()["now"] == "fixture":
                            break
                    except OSError:
                        pass
                    time.sleep(0.05)
                else:
                    raise AssertionError("proxy selection did not survive restart")
                for domain, expected in (("a.direct.test", "direct"), ("a.proxy.test", "proxy"),
                                         ("api.other.test", "direct"), ("apixother.test", "proxy"),
                                         ("special.example.test", "proxy"), ("other.example.test", "direct"),
                                         ("foo-123.test", "direct"), ("foo-abc.test", "proxy"),
                                         ("a.ruleset.test", "direct"), ("ruleset.test", "proxy"),
                                         ("excluded.ruleset.test", "proxy"), ("logical.test", "direct"),
                                         ("www.unanchored.example", "direct"), ("UPPER.test", "proxy"),
                                         ("MiXeD.test", "direct"), ("FOO-456.test", "direct")):

                    dns_test.query(front, domain)
                    expected_group = "cn" if expected == "direct" else "global"
                    assert any(call["name"] == domain.lower() + "." for r in resolvers[expected_group] for call in r.calls), domain
                    assert socks_http(mixed, domain, origin) == expected, domain
                    assertions += 1
                dns_test.query(front, "connection.direct.test")
                assert any(c["name"] == "connection.direct.test." for resolver in resolvers["cn"] for c in resolver.calls)
                assert socks_http(mixed, "connection.direct.test", origin) == "proxy"
                assert socks_http(mixed, "127.0.0.1", origin) == "proxy"
                assertions += 3
                for domain in ("blocked.test", "x.blocked.test"):
                    try:
                        socks_http(mixed, domain, origin)
                    except (OSError, EOFError):
                        assertions += 1
                    else:
                        raise AssertionError("blocked connection reached an origin")
                assert dns_test.marker(dns_test.query(front, "route.proxy.test")) == "127.0.0.1"
                assert dns_test.marker(dns_test.query(front, "sf.race.proxy.test")) == "127.0.0.1"
                time.sleep(0.15)
                assert all(("127.0.0.1", port) in proxy_calls for port in global_ports), "both TLS legs must cross proxy"
                cn_ports = {u["port"] for u in groups["cn"]["upstreams"]}
                assert not any(port in cn_ports for _, port in proxy_calls), "CN transport must stay direct"
                assert any(c["name"] == "proxy-node.example." for r in resolvers["cn"] for c in r.calls), "proxy endpoint requires explicit CN bootstrap"
                assert not any(c["name"] == "proxy-node.example." for r in resolvers["global"] for c in r.calls), "proxy endpoint bootstrap recursed through GLOBAL"
                assertions += 6
                proxy_context.__exit__(None, None, None)
                # The registered cleanup is idempotent for this fixture.
                assert dns_test.query(front, "allfail-after-stop.proxy.test").rcode() == 2
                assert dns_test.marker(dns_test.query(front, "still-online.direct.test")) == "127.0.0.1"
                assertions += 2
                process.terminate()
                process.wait(timeout=5)
                assert dns_test.query(front, "allfail-without-process.proxy.test").rcode() == 2
                assert dns_test.marker(dns_test.query(front, "direct-without-process.direct.test")) == "127.0.0.1"
                assertions += 2

        except BaseException:
            print((root / "sing-box.log").read_text()[-10000:])
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

        # A hostname sent over SOCKS must become an IPv4 destination before
        # reaching a remote proxy. Reopen the real stack in each family mode.
        family_policy = policy | {"routeFragments": policy["routeFragments"] | {
            "30-family.json": {"rules": [{"domain_suffix": "proxy.test", "outbound": "proxy"}]}
        }}
        family_model = assembler.domain_policy.compile_policy(family_policy | {
            "connectionFragments": base["_connectionFragments"]})
        with socks_server(global_ports, origin) as (family_proxy, calls):
            provider.write_text(json.dumps({"outbounds": [node | {"server_port": family_proxy}]}))
            for only4 in (True, False):
                directory = root / ("ipv4" if only4 else "restored")
                compiler.compile_policy(family_policy, directory, family_model, only4)
                template.write_text(json.dumps(assembler.assemble(base, family_policy,
                    json.loads((directory / "transports.json").read_text()), family_model, only4)))
                renderer.render(template, provider, output, args.sing_box)
                with proxy_process(args.sing_box, root, log, mixed), \
                     dns_test.processes(args, family_policy, directory, ipv4_only=only4):
                    answer = dns_test.query(front, "family.proxy.test", "AAAA")
                    assert answer.rcode() == 0 and bool(answer.answer) != only4
                    assert socks_http(mixed, "family.direct.test", origin) == "direct"
                    calls.clear()
                    assert socks_http(mixed, "family.proxy.test", origin) == "proxy"
                    destination = "127.0.0.1" if only4 else "family.proxy.test"
                    assert (destination, origin) in calls, calls
                    if only4:
                        try:
                            socks_http(mixed, "::1", origin)
                        except (OSError, EOFError):
                            pass
                        else:
                            raise AssertionError("IPv6 destination reached the remote proxy in IPv4 mode")
                    else:
                        assert socks_http(mixed, "::1", origin) == "direct"
                    assertions += 5

        # Run the standalone configuration after all DNS workers have exited.
        # Its local resolver uses the OS hosts/resolver configuration.
        with socks_server([], origin) as (standalone_proxy, calls):
            standalone = templates["standalone"]
            for inbound in standalone["inbounds"]:
                inbound["listen_port"] = mixed
            template.write_text(json.dumps(assembler.assemble(standalone, {
                "routeFragments": {"50-local.json": {"rules": [
                    {"domain": "localhost", "outbound": "direct"}, {"domain": "blocked.example", "action": "reject"}
                ]}}})))
            provider.write_text(json.dumps({"outbounds": [{"type": "socks", "tag": "standalone",
                "server": "localhost", "server_port": standalone_proxy}]}))
            renderer.render(template, provider, output, args.sing_box)
            with proxy_process(args.sing_box, root, log, mixed):
                assert socks_http(mixed, "localhost", origin) == "direct"
                assert socks_http(mixed, "remote.example", origin) == "proxy"
                try:
                    socks_http(mixed, "blocked.example", origin)
                except (OSError, EOFError):
                    pass
                else:
                    raise AssertionError("standalone blocked route reached origin")
                assert ("remote.example", origin) in calls
                assertions += 4
            remote_ip_rules(args.sing_box, root / "remote-rules")
            print(json.dumps({"passed": assertions, "scope": "DNS + proxy egress, remote rule updates and offline cache"}))


if __name__ == "__main__":
    main()
