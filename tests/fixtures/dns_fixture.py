"""Authenticated local DoT/HTTP2 DoH fixtures with observable race branches."""
import contextlib
import socket
import socketserver
import ssl
import struct
import subprocess
import threading
import time

import dns.edns
import dns.message
import dns.rcode
import dns.rrset
import h2.config
import h2.connection
import h2.events

from .network_fixture import TCPServer, read_exact, serve


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def certificate(root):
    key, cert = root / "fixture.key", root / "fixture.crt"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "1",
                    "-subj", "/CN=resolver.test", "-addext", "subjectAltName=DNS:resolver.test"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    return key, cert


class Resolver:
    def __init__(self, group, branch):
        self.group, self.branch, self.calls = group, branch, []
        self.barriers = {}
        self.delay = 0.01 if branch == 0 else 0.09
        marker = 11 if group == "cn" else 22
        self.ipv4, self.ipv6 = f"192.0.2.{marker}", f"2001:db8::{marker}"

    def response(self, wire):
        query = dns.message.from_wire(wire)
        name = query.question[0].name.to_text().lower()
        self.calls.append({"name": name, "type": query.question[0].rdtype,
                           "time": time.monotonic(), "ecs": [str(o) for o in query.options if o.otype == 8]})
        if name in self.barriers:
            self.barriers[name].wait()
        time.sleep(self.delay)
        reply = dns.message.make_response(query)
        reply.use_edns(edns=0, payload=1232)
        first = name.split(".")[0]
        rcodes = {"sf": 2, "refused": 5, "formerr": 1, "badvers": 16, "nx": 3}
        if first.startswith("allfail"):
            reply.set_rcode(2 if self.branch == 0 else 5)
        elif self.branch == 0 and first in rcodes:
            reply.set_rcode(rcodes[first])
        elif self.branch == 0 and first == "nodata":
            pass
        else:
            qtype = query.question[0].rdtype
            text = {1: self.ipv4, 28: self.ipv6, 15: f"10 mail.{name}",
                    16: '"' + self.group + '"', 64: f"1 . alpn=\"h2\" ipv4hint={self.ipv4}",
                    65: f"1 . alpn=\"h2\" ipv4hint={self.ipv4}"}.get(qtype)
            if first == "large" and qtype == 16:
                text = " ".join('"' + "x" * 200 + '"' for _ in range(200))
            if text is not None:
                reply.answer.append(dns.rrset.from_text(query.question[0].name, 60, "IN", qtype, text))
        if first == "records":
            reply.authority.append(dns.rrset.from_text(name, 120, "IN", "NS", "ns.fixture.example."))
            reply.additional.append(dns.rrset.from_text("ns.fixture.example.", 180, "IN", "A", "192.0.2.53"))
        return reply.to_wire(max_size=65535)


@contextlib.contextmanager
def encrypted_server(resolver, protocol, key, cert, hostname="resolver.test", address="127.0.0.1", port=0):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    context.set_alpn_protocols(["h2"] if protocol == "https" else ["dot"])

    class Server(TCPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(8)
            try:
                return context.wrap_socket(connection, server_side=True), address
            except (ssl.SSLError, OSError):
                connection.close()
                raise

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                if protocol == "tls":
                    while True:
                        size = struct.unpack("!H", read_exact(self.request, 2))[0]
                        reply = resolver.response(read_exact(self.request, size))
                        self.request.sendall(struct.pack("!H", len(reply)) + reply)
                else:
                    conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
                    conn.initiate_connection()
                    self.request.sendall(conn.data_to_send())
                    bodies = {}
                    while data := self.request.recv(65535):
                        for event in conn.receive_data(data):
                            if isinstance(event, h2.events.RequestReceived):
                                headers = dict(event.headers)
                                assert headers[b":method"] == b"POST"
                                assert headers[b":authority"] == hostname.encode()
                                assert headers[b":path"] == b"/dns-query"
                                bodies[event.stream_id] = bytearray()
                            elif isinstance(event, h2.events.DataReceived):
                                bodies[event.stream_id].extend(event.data)
                                conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                            elif isinstance(event, h2.events.StreamEnded):
                                reply = resolver.response(bytes(bodies.pop(event.stream_id)))
                                conn.send_headers(event.stream_id, [(":status", "200"), ("content-type", "application/dns-message")])
                                while reply:
                                    chunk, reply = reply[:conn.max_outbound_frame_size], reply[conn.max_outbound_frame_size:]
                                    conn.send_data(event.stream_id, chunk, end_stream=not reply)
                        self.request.sendall(conn.data_to_send())
            except (OSError, EOFError):
                pass

    with serve(Server((address, port), Handler)) as server:
        yield server.server_address[1]


@contextlib.contextmanager
def plain_server(resolver):
    class Stream(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                while True:
                    length = struct.unpack("!H", read_exact(self.request, 2))[0]
                    reply = resolver.response(read_exact(self.request, length))
                    self.request.sendall(struct.pack("!H", len(reply)) + reply)
            except (OSError, EOFError):
                pass

    class Datagram(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            sock.sendto(resolver.response(data), self.client_address)

    with serve(TCPServer(("127.0.0.1", 0), Stream)) as tcp:
        port = tcp.server_address[1]
        with serve(socketserver.ThreadingUDPServer(("127.0.0.1", port), Datagram)):
            yield port
