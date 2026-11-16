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
        handle.write(json.dumps({"kind": kind, "peer": str(ipaddress.ip_address(peer[0])), "peerPort": peer[1],
                                 "data": data.decode(errors="replace"), "time": time.monotonic()}) + "\n")
        handle.flush()


def continuous(host, policy, protocol, instance, state):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    label = f"{policy}/{6 if family == socket.AF_INET6 else 4}/{protocol}"
    connection = sequence = attempts = received = 0
    local = None
    phase = "boot"
    status = state / (label.replace("/", "-") + ".json")

    def begin():
        nonlocal phase, attempts, received
        current = (state / "phase").read_text().strip() if (state / "phase").exists() else "boot"
        if phase != current:
            phase, attempts, received = current, 0, 0

    def progress(success=False):
        nonlocal attempts, received
        attempts += 1
        received += success
        pending = status.with_suffix(".pending")
        pending.write_text(json.dumps({"instance": instance, "phase": phase, "flow": label,
                                       "attempts": attempts, "received": received, "sequence": sequence,
                                       "connection": connection, "local": local}) + "\n")
        pending.replace(status)
    while True:
        connection += 1
        local = None
        begin()
        connected = False
        try:
            with socket.socket(family, socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM) as sock, contextlib.ExitStack() as resources:
                sock.settimeout(0.5)
                if protocol == "tcp":
                    sock.connect((host, 18082))
                connected = True
                reader = resources.enter_context(sock.makefile("rb")) if protocol == "tcp" else None
                while True:
                    begin()
                    sequence += 1
                    data = f"/continuous/{label}/{instance}/{connection}/{phase}/{sequence}\n".encode()
                    success = False
                    try:
                        if protocol == "tcp":
                            sock.sendall(data)
                            if not reader.readline(100):
                                break
                        else:
                            sock.sendto(data, (host, 18081))
                            sock.recv(100)
                        success = True
                    finally:
                        local = sock.getsockname()
                        progress(success)
                    time.sleep(0.1)
        except OSError:
            if not connected:
                progress()
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
        state = Path("/run/continuous")
        state.mkdir(exist_ok=True)
        threads = []
        for host, policy in (("192.0.2.30", "direct"), ("2001:db8:1::30", "direct"),
                             ("198.51.100.30", "proxy"), ("2001:db8:2::30", "proxy")):
            for protocol in ("tcp", "udp"):
                worker = threading.Thread(target=continuous, args=(host, policy, protocol, instance, state), daemon=True)
                worker.start()
                threads.append(worker)
        while all(worker.is_alive() for worker in threads):
            time.sleep(0.1)
        raise RuntimeError("continuous traffic worker exited unexpectedly")
    with contextlib.ExitStack() as stack:
        if args.mode == "dns":
            # Hysteria server's own resolver, reachable only inside the fixture.
            stack.enter_context(dns_server("198.51.100.30", "2001:db8:2::30", "127.0.0.1", 15353))
            stack.enter_context(dns_server("192.168.1.20", "2001:db8:10::20", "0.0.0.0", 53))
            for group, base in (("cn", 24001), ("global", 24003)):
                for branch, protocol in enumerate(("tls", "https")):
                    resolver = Resolver(group, branch)
                    resolver.ipv4 = "192.0.2.30" if group == "cn" else "198.51.100.30"
                    resolver.ipv6 = "2001:db8:1::30" if group == "cn" else "2001:db8:2::30"
                    stack.enter_context(encrypted_server(resolver, protocol, args.key, args.cert,
                                        hostname="dns.test.nix", address="0.0.0.0", port=base + branch))
        else:
            class HTTP(socketserver.BaseRequestHandler):
                def handle(self):
                    self.request.settimeout(3)
                    try:
                        data = self.request.recv(4096)
                        record("tcp", self.client_address, data)
                        body = self.client_address[0].encode()
                        self.request.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                    except OSError:
                        pass
            class UDP(socketserver.BaseRequestHandler):
                def handle(self):
                    data, sock = self.request
                    record("udp", self.client_address, data)
                    sock.sendto(self.client_address[0].encode(), self.client_address)
            class PersistentTCP(socketserver.StreamRequestHandler):
                def handle(self):
                    self.request.settimeout(60)
                    try:
                        while data := self.rfile.readline(4096):
                            record("tcp", self.client_address, data)
                            self.wfile.write(self.client_address[0].encode() + b"\n")
                    except OSError:
                        pass
            class UDP6(UDPServer):
                address_family = socket.AF_INET6

                def server_bind(self):
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    super().server_bind()
            hosts = ("0.0.0.0", "::") if args.mode == "host" else ("192.0.2.30", "198.51.100.30", "2001:db8:1::30", "2001:db8:2::30")
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
