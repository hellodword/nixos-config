"""Independent encrypted resolvers for the VPS deployment scenario."""
import contextlib
import json
from pathlib import Path
import signal
import sys
import time

import dns.flags
import dns.message
import dns.rrset

from .dns_fixture import encrypted_server


class Resolver:
    def __init__(self, branch):
        self.branch = branch

    def response(self, wire):
        query = dns.message.from_wire(wire)
        name = query.question[0].name.to_text().lower()
        with Path(f"/run/vps-dns-{self.branch}.jsonl").open("a") as log:
            log.write(json.dumps({"name": name, "type": query.question[0].rdtype}) + "\n")
        time.sleep(0.01 if self.branch == 0 else 0.08)
        response = dns.message.make_response(query)
        response.flags |= dns.flags.RA
        if name.startswith("allfail.") or (self.branch == 0 and name.startswith("sf.")):
            response.set_rcode(2)
        elif name.startswith("nx."):
            response.set_rcode(3)
        elif query.question[0].rdtype == 1:
            address = "192.0.2.30" if name in {"nts.test.nix.", "cert.test.nix."} else "198.51.100.30"
            response.answer.append(dns.rrset.from_text(name, 60, "IN", "A", address))
        # Recursive clients need the SOA TTL to cache NODATA and NXDOMAIN.
        if response.rcode() in (0, 3) and not response.answer:
            response.authority.append(dns.rrset.from_text(
                query.question[0].name.parent(), 60, "IN", "SOA",
                "ns.fixture.example. hostmaster.fixture.example. 1 60 60 60 60",
            ))
        return response.to_wire()


if __name__ == "__main__":
    branch, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    resolver = Resolver(branch)
    with contextlib.ExitStack() as stack:
        stack.enter_context(encrypted_server(resolver, "tls", key, cert, address=f"192.0.2.{30 + branch}", port=853))
        stack.enter_context(encrypted_server(resolver, "https", key, cert, hostname=f"dns.test.nix:{24443 + branch}",
                                             address="198.51.100.30", port=24443 + branch))
        signal.pause()
