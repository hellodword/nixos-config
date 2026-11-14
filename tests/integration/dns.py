#!/usr/bin/env python3
"""Black-box tests of the shipped dnsdist/dnsproxy processes and compiler."""
import argparse
import base64
import contextlib
import grp
import os
from types import SimpleNamespace
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import threading

import dns.edns
import dns.message
import dns.query
import dns.rcode

from tests.fixtures.dns_fixture import Resolver, certificate, encrypted_server, free_port, plain_server

from tests.support import ROOT, load_script

runtime = load_script("network/runtime_policy.py")


@contextlib.contextmanager
def processes(args, config, root, fragments=None, ipv4_only=False):
    root.mkdir(parents=True, exist_ok=True)
    config = {**config, "logSocket": str(root / "dnstap.sock")}
    source = root / "policy.json"
    source.write_text(json.dumps(config))
    runtime.prepare(SimpleNamespace(policy=source, fragments=fragments or root / "route.d", dnsdist=args.dnsdist,
                    sing_box=None, provider=None, base=None, action="check", connections=None, bootstrap=False,
                    ipv4_only=ipv4_only, rules_directory=None, group=grp.getgrgid(os.getgid()).gr_name), root)
    check = subprocess.run([args.dnsdist, "--check-config", "-C", str(root / "dnsdist.conf")], capture_output=True, text=True)
    assert check.returncode == 0, check.stdout + check.stderr
    with contextlib.ExitStack() as stack:
        collector = json.loads(Path(args.collector_template).read_text())
        collector["pipelines"][0]["dnstap"]["sock-path"] = config["logSocket"]
        collector_config = root / "collector.json"
        collector_config.write_text(json.dumps(collector))
        events = stack.enter_context((root / "events.jsonl").open("w"))
        running = [subprocess.Popen([args.dnscollector, "-config", str(collector_config)], stdout=events, stderr=events)]
        for _ in range(100):
            if Path(config["logSocket"]).exists():
                break
            if running[0].poll() is not None:
                raise AssertionError((root / "events.jsonl").read_text())
            time.sleep(0.05)
        for group in config["groups"]:
            if not (root / f"race-{group}.json").exists():
                continue
            log = stack.enter_context((root / f"race-{group}.log").open("w"))
            running.append(subprocess.Popen([args.dnsproxy, "--config-path", str(root / f"race-{group}.json")], stdout=log, stderr=log))
        log = stack.enter_context((root / "dnsdist.log").open("w"))
        running.append(subprocess.Popen([args.dnsdist, "--supervised", "--disable-syslog", "-C", str(root / "dnsdist.conf")], stdout=log, stderr=log, stdin=subprocess.DEVNULL))
        try:
            for _ in range(100):
                if any(p.poll() is not None for p in running):
                    raise AssertionError("DNS process exited: " + (root / "dnsdist.log").read_text())
                try:
                    with socket.create_connection(("127.0.0.1", config["frontPort"]), timeout=0.1):
                        pass
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("DNS stack not ready")
            assert query(config["frontPort"], "ready.example.org").rcode() == 0
            yield
        except BaseException:
            for handle in (root / "dnsdist.log", root / "race-cn.log", root / "race-global.log", root / "events.jsonl"):
                if handle.exists():
                    print(handle.name + ":\n" + handle.read_text()[-12000:], flush=True)
            raise
        finally:
            for process in running:
                process.terminate()
            for process in running:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def query(port, name, kind="A", tcp=False, ecs=False, address="127.0.0.1"):
    message = dns.message.make_query(name, kind)
    if ecs:
        message.use_edns(options=[dns.edns.ECSOption("192.0.2.0", 24)])
    return (dns.query.tcp if tcp else dns.query.udp)(message, address, port=port, timeout=8)


def marker(message):
    return message.answer[0][0].to_text() if message.answer else None


def read_events(path):
    events = []
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not event.get("extracted", {}).get("dns_payload"):
            continue
        message = dns.message.from_wire(base64.b64decode(event["extracted"]["dns_payload"]))
        events.append({"name": message.question[0].name.to_text().rstrip(".").lower(), "message": message,
                       "identity": event["dnstap"]["identity"], "policy": json.loads(event["dnstap"]["extra"])})
    return events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dnsdist", required=True)
    parser.add_argument("--dnsproxy", required=True)
    parser.add_argument("--dnscollector", required=True)
    parser.add_argument("--collector-template", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="dns-contract-") as directory, contextlib.ExitStack() as stack:
        root = Path(directory)
        key, cert = certificate(root)
        resolvers, groups = {}, {}
        for group in ("cn", "global"):
            groups[group] = {"upstreams": []}
            resolvers[group] = []
            for branch, protocol in enumerate(("tls", "https")):
                resolver = Resolver(group, branch)
                port = stack.enter_context(encrypted_server(resolver, protocol, key, cert))
                groups[group]["upstreams"].append({"protocol": protocol, "address": "127.0.0.1", "port": port, "serverName": "resolver.test"})
                resolvers[group].append(resolver)
        tailnet = Resolver("tailnet", 0)
        tailnet.ipv4 = "192.0.2.33"
        tailnet_port = stack.enter_context(plain_server(tailnet))
        # Reserve adjacent internal ranges separately from ephemeral fixture ports.
        config = {"groups": groups, "caStore": str(cert),
                  "tailnetUpstream": {"address": "127.0.0.1", "port": tailnet_port},
                  "frontPort": free_port(), "bootstrapPort": free_port(),
                  "legPortBase": 15400, "racePortBase": 15500, "tunnelPortBase": 15600,
                  "routeFragments": {
                      "00-defaults.json": {"final": "proxy"},
                      "10-tailnet.json": {"rules": [{"domain_suffix": "ts.net", "outbound": "tailnet"}]},
                      "20-private.json": {"rules": [{"domain_suffix": ["home.arpa", "10.in-addr.arpa"], "outbound": "private"}]},
                      "40-explicit.json": {"rules": [
                          {"domain": "override.example.test", "outbound": "direct"},
                          {"domain_regex": r"^foo-\d+\.test$", "outbound": "direct"},
                          {"domain_regex": r"regex-over-exact\.test", "outbound": "proxy"},
                          {"domain_regex": r"ordered-\d+\.test", "outbound": "proxy"},
                          {"domain_regex": r"ordered-.*\.test", "outbound": "direct"},
                          {"domain": ["api.other.test", "regex-over-exact.test"], "outbound": "direct"},
                          {"domain_suffix": "deep.nested.example.test", "outbound": "proxy"},
                          {"domain_suffix": "nested.example.test", "outbound": "direct"},
                          {"domain_suffix": "example.test", "outbound": "proxy"},
                          {"domain_suffix": "blocked.test", "action": "reject"},
                      ]},
                      "80-cn.json": {"rules": [{"domain_suffix": "cn.test", "outbound": "direct"}]},
                  }}
        port = config["frontPort"]
        assertions = 0
        def check(condition, description):
            nonlocal assertions
            assert condition, description
            assertions += 1

        with processes(args, config, root / "first"):
            cases = {"foo-123.test": 11, "FOO-234.TEST.": 11, "foo-abc.test": 22,
                     "www.foo-123.test": 22, "foox123.test": 22, "ordered-123.test": 22,
                     "override.example.test": 11, "www.example.test": 22,
                     "a.nested.example.test": 11, "a.deep.nested.example.test": 22,
                     "api.other.test": 11, "apixother.test": 22}
            cases["regex-over-exact.test"] = 22
            for tcp in (False, True):
                for domain, expected in cases.items():
                    check(marker(query(port, domain, tcp=tcp)) == f"192.0.2.{expected}", domain)
                for kind in ("A", "AAAA", "HTTPS", "MX", "TXT"):
                    reply = query(port, "types.cn.test", kind, tcp=tcp)
                    check(reply.rcode() == 0 and bool(reply.answer), f"{kind} routing")
                for rcode in ("sf", "refused", "formerr", "badvers"):
                    reply = query(port, f"{rcode}.{tcp}.cn.test", tcp=tcp)
                    check(marker(reply) == "192.0.2.11", f"fast {rcode} must not win")
                check(query(port, f"nx.{tcp}.cn.test", tcp=tcp).rcode() == 3, "NXDOMAIN qualifies")
                reply = query(port, f"nodata.{tcp}.cn.test", tcp=tcp)
                check(reply.rcode() == 0 and not reply.answer, "NODATA qualifies")
                check(query(port, f"allfail-{tcp}.cn.test", tcp=tcp).rcode() == 2, "all fail -> SERVFAIL")
            check(marker(query(port, "dual.cn.test", "AAAA", address="::1")) == "2001:db8::11", "IPv6 listener")
            for domain in ("private.home.arpa", "1.0.0.10.in-addr.arpa", "blocked.test"):
                before = sum(len(r.calls) for group in resolvers.values() for r in group)
                check(query(port, domain).rcode() == 3, "private or blocked name")
                time.sleep(0.1)
                check(sum(len(r.calls) for group in resolvers.values() for r in group) == before, "private name leaked")
            check(marker(query(port, "machine.ts.net")) == "192.0.2.33", "Tailnet binding")
            check(query(port, "ecs.cn.test", ecs=True).rcode() == 5, "client ECS refused")
            barrier = threading.Barrier(2, timeout=4)
            for resolver in resolvers["cn"]:
                resolver.barriers["fanout.cn.test."] = barrier
            query(port, "fanout.cn.test")
            arrivals = [[c for c in r.calls if c["name"] == "fanout.cn.test."] for r in resolvers["cn"]]
            check(all(len(c) == 1 for c in arrivals), "every branch receives a cache miss")
            check(not barrier.broken, "both upstream branches start before either responds")
            check(all(c[0]["ecs"] == ["ECS 0.0.0.0/0 scope/0"] for c in arrivals), "fixed ECS /0")
            query(port, "fanout.cn.test")
            time.sleep(0.12)
            check(all(len([c for c in r.calls if c["name"] == "fanout.cn.test."]) == 1 for r in resolvers["cn"]), "cache avoids new fanout")
            check(marker(query(port, "isolation.test")) == "192.0.2.22", "global cache view")
            check(marker(query(config["bootstrapPort"], "isolation.test")) == "192.0.2.11", "CN cache isolated")
            large_reply = query(port, "large.cn.test", "TXT", tcp=True)
            check(large_reply.answer[0][0].strings == (b"x" * 200,) * 200, "large TCP response")
            record_reply = query(port, "records.cn.test", "HTTPS")
            records_cached = query(port, "records.cn.test", "HTTPS")
            for _ in range(100):
                events = read_events(root / "first/events.jsonl")
                if sum(e["name"] == "records.cn.test" and e["identity"] == "dnsdist-client" and bool(e["message"].flags & 0x8000) for e in events) == 2:
                    break
                time.sleep(0.1)
            responses = [e for e in events if e["message"].flags & 0x8000]
            for name, source, group in (("records.cn.test", "upstream", "cn"), ("records.cn.test", "cache", "cn"),
                                        ("private.home.arpa", "self", "private"), ("machine.ts.net", "upstream", "tailnet"),
                                        ("ecs.cn.test", "self", "refused"), ("large.cn.test", "upstream", "cn")):
                selected = [e for e in responses if e["name"] == name and e["identity"] == "dnsdist-client" and e["policy"]["response_source"] == source]
                check(bool(selected), f"client response logged: {name}/{source}")
                check(selected[0]["policy"]["group"] == group, f"logged upstream group: {name}")
                check(bool(selected[0]["policy"]["generation"] and selected[0]["policy"]["rule"]), "rule provenance")
                if name == "records.cn.test":
                    expected = record_reply if source == "upstream" else records_cached
                    for field in ("answer", "authority", "additional"):
                        check([rr.to_text() for rr in getattr(selected[0]["message"], field)] == [rr.to_text() for rr in getattr(expected, field)], "full response " + field)
                elif name == "large.cn.test":
                    check(selected[0]["message"].answer == large_reply.answer, "complete large response logged")
            failed = [e for e in responses if e["identity"] == "dnsdist-leg" and e["name"] == "sf.false.cn.test"]
            check({e["message"].rcode() for e in failed} == {0, 2}, "both successful and discarded upstream replies logged")
            check({e["policy"]["upstream"]["protocol"] for e in failed} == {"tls", "https"}, "real upstream transports logged")
            query_events = [e for e in events if e["name"] == "records.cn.test" and e["identity"] == "dnsdist-client" and not (e["message"].flags & 0x8000)]
            check(len(query_events) == 2, "cache hit and miss queries logged")

        # Changing policy and ECS restarts dnsdist, dropping all prior packet caches.
        config["routeFragments"]["05-local.json"] = {"rules": [{"domain": "isolation.test", "outbound": "direct"}]}
        groups["cn"]["ecs4"] = "198.51.100.0/24"
        groups["cn"]["upstreams"][0]["serverName"] = "wrong.test"
        with processes(args, config, root / "changed"):
            before = len(resolvers["cn"][0].calls)
            check(marker(query(port, "isolation.test")) == "192.0.2.11", "policy change clears cache")
            check(marker(query(port, "tls.cn.test")) == "192.0.2.11", "valid TLS branch survives")
            check(query(port, "large.cn.test", "TXT", tcp=True).answer == large_reply.answer, "large DoH response")
            check(len(resolvers["cn"][0].calls) == before, "wrong TLS identity cannot resolve")
            check(resolvers["cn"][1].calls[-1]["ecs"] == ["ECS 198.51.100.0/24 scope/0"], "new fixed ECS")
        print(json.dumps({"passed": assertions, "scope": "real dnsdist+dnsproxy, loopback DoT/HTTP2 DoH, policy/cache/faults"}))


if __name__ == "__main__":
    main()
