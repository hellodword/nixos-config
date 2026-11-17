#!/usr/bin/env python3
"""Black-box tests of the shipped dnsdist/dnsproxy processes and compiler."""
import argparse
import contextlib
import json
from pathlib import Path
import tempfile
import time
import threading
import tomllib
from concurrent.futures import ThreadPoolExecutor

from tests.fixtures.dns_fixture import Resolver, certificate, encrypted_server, free_port, plain_server


from tests.fixtures.dns_stack import processes, query, marker, read_events
from tests.support import ROOT


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
            upstreams = (tomllib.loads((ROOT / "data/network/direct-dns.toml").read_text())["upstreams"]
                         if group == "cn" else [{"protocol": protocol} for protocol in ("tls", "https")])
            for branch, upstream in enumerate(upstreams):
                protocol = upstream["protocol"]
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

        def ordered_query(name, tcp, invalid=False, winner=0):
            gates = [(threading.Event(), threading.Event()) for _ in resolvers["cn"]]
            for resolver, gate in zip(resolvers["cn"], gates):
                resolver.gates[name.lower() + "."] = gate
            with ThreadPoolExecutor(max_workers=1) as executor:
                result = executor.submit(query, port, name, tcp=tcp, timeout=20)
                try:
                    for arrived, _ in gates:
                        check(arrived.wait(8), f"upstream received {name}")
                    gates[0 if invalid else winner][1].set()
                    if invalid:
                        deadline = time.monotonic() + 8
                        while True:
                            replies = read_events(root / "first/events.jsonl")
                            if any(e["name"] == name.lower() and e["identity"] == "dnsdist-leg"
                                   and e["message"].flags & 0x8000 and e["message"].rcode() != 0
                                   for e in replies):
                                break
                            assert time.monotonic() < deadline, f"first upstream response missing: {name}"
                            time.sleep(0.05)
                        check(not result.done(), f"discarded response waits for the other upstream: {name}")
                        gates[-1][1].set()
                    return result.result(timeout=8)
                finally:
                    for _, release in gates:
                        release.set()

        with processes(args, config, root / "first"):
            for winner in range(len(resolvers["cn"])):
                name = f"winner-{winner}.cn.test"
                for branch, resolver in enumerate(resolvers["cn"]):
                    resolver.ipv4_by_name[name] = f"192.0.2.{50 + branch}"
                check(marker(ordered_query(name, tcp=False, winner=winner)) == f"192.0.2.{50 + winner}",
                      f"branch {winner} wins while the other branches are pending")
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
                    reply = ordered_query(f"{rcode}.{tcp}.cn.test", tcp, invalid=True)
                    check(marker(reply) == "192.0.2.11", f"fast {rcode} must not win")
                check(ordered_query(f"nx.{tcp}.cn.test", tcp).rcode() == 3, "NXDOMAIN qualifies")
                reply = ordered_query(f"nodata.{tcp}.cn.test", tcp)
                check(reply.rcode() == 0 and not reply.answer, "NODATA qualifies")
                check(query(port, f"allfail-{tcp}.cn.test", tcp=tcp).rcode() == 2, "all fail -> SERVFAIL")
            check(marker(query(port, "dual.cn.test", "AAAA", address="::1")) == "2001:db8::11", "IPv6 listener")
            for domain in ("private.home.arpa", "1.0.0.10.in-addr.arpa", "blocked.test"):
                check(query(port, domain).rcode() == 3, "private or blocked name")
                check(not any(c["name"] == domain + "." for group in resolvers.values()
                              for r in group for c in r.calls), "private name leaked")
            check(marker(query(port, "machine.ts.net")) == "192.0.2.33", "Tailnet binding")
            check(query(port, "ecs.cn.test", ecs=True).rcode() == 5, "client ECS refused")
            barrier = threading.Barrier(len(resolvers["cn"]), timeout=4)
            for resolver in resolvers["cn"]:
                resolver.barriers["fanout.cn.test."] = barrier
            query(port, "fanout.cn.test")
            arrivals = [[c for c in r.calls if c["name"] == "fanout.cn.test."] for r in resolvers["cn"]]
            check(all(len(c) == 1 for c in arrivals), "every branch receives a cache miss")
            check(not barrier.broken, "all upstream branches start before any responds")
            check(all(c[0]["ecs"] == ["ECS 0.0.0.0/0 scope/0"] for c in arrivals), "fixed ECS /0")
            query(port, "fanout.cn.test")
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
            # The stack has completed later queries and published its response
            # records; inspect the specific names rather than unrelated totals.
            for domain in ("private.home.arpa", "1.0.0.10.in-addr.arpa", "blocked.test"):
                check(not any(c["name"] == domain + "." for group in resolvers.values()
                              for r in group for c in r.calls), "private name leaked")
            check(all(len([c for c in r.calls if c["name"] == "fanout.cn.test."]) == 1
                      for r in resolvers["cn"]), "cache avoids new fanout")
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
