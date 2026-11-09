"""Synthetic DNS/Hysteria2/observer fixtures for the kernel test."""
import argparse
import contextlib
import fcntl
import ipaddress
import json
from pathlib import Path
import signal
import socket
import socketserver
import ssl
import threading
import time
import uuid

from .dns_fixture import Resolver, encrypted_server
from .network_fixture import TCPServer, TCPServer6, UDPServer, dns_server, serve

def record(kind, peer, data):
    with Path("/run/observations.jsonl").open("a") as handle:
        # The final snapshot takes a shared lock on this same file. Each
        # writer opens its own descriptor, so this also serializes threads.
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.write(json.dumps({"kind": kind, "peer": str(ipaddress.ip_address(peer)),
                                 "data": data.decode(errors="replace"), "time": time.monotonic()}) + "\n")
        handle.flush()


def continuous(host, policy, protocol, instance):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    label = f"{policy}/{6 if family == socket.AF_INET6 else 4}/{protocol}"
    connection = sequence = 0
    while True:
        connection += 1
        try:
            with socket.socket(family, socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM) as sock:
                sock.settimeout(0.5)
                if protocol == "tcp":
                    sock.connect((host, 18082))
                while True:
                    sequence += 1
                    data = f"/continuous/{label}/{instance}/{connection}/{sequence}\n".encode()
                    if protocol == "tcp":
                        sock.sendall(data)
                        if not sock.recv(100):
                            break
                    else:
                        sock.sendto(data, (host, 18081))
                        sock.recv(100)
                    time.sleep(0.1)
        except OSError:
            pass
        time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["dns", "target", "host", "continuous"])
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--origin", default="local")
    args = parser.parse_args()
    if args.mode == "continuous":
        instance = f"{args.origin}-{uuid.uuid4().hex}"
        for host, policy in (("198.18.0.30", "direct"), ("2001:db8:1::30", "direct"),
                             ("198.19.0.30", "proxy"), ("2001:db8:2::30", "proxy")):
            for protocol in ("tcp", "udp"):
                threading.Thread(target=continuous, args=(host, policy, protocol, instance), daemon=True).start()
        signal.pause()
        return
    with contextlib.ExitStack() as stack:
        if args.mode == "dns":
            # Hysteria server's own resolver, reachable only inside the fixture.
            stack.enter_context(dns_server("198.19.0.30", "2001:db8:2::30", "127.0.0.1", 15353))
            for group, base in (("cn", 24001), ("global", 24003)):
                for branch, protocol in enumerate(("tls", "https")):
                    resolver = Resolver(group, branch)
                    resolver.ipv4 = "198.18.0.30" if group == "cn" else "198.19.0.30"
                    resolver.ipv6 = "2001:db8:1::30" if group == "cn" else "2001:db8:2::30"
                    stack.enter_context(encrypted_server(resolver, protocol, args.key, args.cert,
                                        hostname="dns.test.nix", address="0.0.0.0", port=base + branch))
        else:
            class HTTP(socketserver.BaseRequestHandler):
                def handle(self):
                    self.request.settimeout(3)
                    try:
                        data = self.request.recv(4096)
                        record("tcp", self.client_address[0], data)
                        body = self.client_address[0].encode()
                        self.request.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                    except OSError:
                        pass
            class UDP(socketserver.BaseRequestHandler):
                def handle(self):
                    data, sock = self.request
                    record("udp", self.client_address[0], data)
                    sock.sendto(self.client_address[0].encode(), self.client_address)
            class PersistentTCP(socketserver.StreamRequestHandler):
                def handle(self):
                    self.request.settimeout(3)
                    try:
                        while data := self.rfile.readline(4096):
                            record("tcp", self.client_address[0], data)
                            self.wfile.write(self.client_address[0].encode() + b"\n")
                    except OSError:
                        pass
            class UDP6(UDPServer):
                address_family = socket.AF_INET6

                def server_bind(self):
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    super().server_bind()
            hosts = ("0.0.0.0", "::") if args.mode == "host" else ("198.18.0.30", "198.19.0.30", "2001:db8:1::30", "2001:db8:2::30")
            for host in hosts:
                stack.enter_context(serve((TCPServer6 if ":" in host else TCPServer)((host, 18080), HTTP)))
                stack.enter_context(serve((UDP6 if ":" in host else UDPServer)((host, 18081), UDP)))
                stack.enter_context(serve((TCPServer6 if ":" in host else TCPServer)((host, 18082), PersistentTCP)))
                if args.cert:
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(args.cert, args.key)
                    server = (TCPServer6 if ":" in host else TCPServer)((host, 18087), HTTP)
                    server.socket = context.wrap_socket(server.socket, server_side=True)
                    stack.enter_context(serve(server))
        signal.pause()


if __name__ == "__main__":
    main()
