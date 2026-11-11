"""Synthetic DNS/egress fixtures; loopback by default, explicit VM LAN optional."""
import contextlib
import ipaddress
import select
import socket
import socketserver
import struct
import threading


def read_exact(sock, size):
    result = b""
    while len(result) < size:
        block = sock.recv(size - len(result))
        if not block:
            raise EOFError("short socket read")
        result += block
    return result


def dns_question(data):
    offset, labels = 12, []
    while data[offset]:
        size = data[offset]
        labels.append(data[offset + 1:offset + 1 + size].decode("ascii"))
        offset += size + 1
    offset += 1
    kind = struct.unpack("!H", data[offset:offset + 2])[0]
    return ".".join(labels), kind, offset + 4


def dns_query(port, domain, kind=1, tcp=False, address="127.0.0.1"):
    wire = b"".join(bytes([len(label)]) + label.encode("ascii") for label in domain.split(".")) + b"\0"
    request = struct.pack("!6H", 0x1029, 0x100, 1, 0, 0, 0) + wire + struct.pack("!HH", kind, 1)
    with socket.socket(socket.AF_INET6 if ":" in address else socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        sock.connect((address, port))
        if tcp:
            sock.sendall(struct.pack("!H", len(request)) + request)
            reply = read_exact(sock, struct.unpack("!H", read_exact(sock, 2))[0])
        else:
            sock.send(request)
            reply = sock.recv(65535)
    rcode = struct.unpack("!H", reply[2:4])[0] & 15
    answer_count = struct.unpack("!H", reply[6:8])[0]
    answer = str(ipaddress.ip_address(reply[-(4 if kind == 1 else 16):])) if answer_count else None
    return rcode, answer


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCPServer6(TCPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


@contextlib.contextmanager
def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


@contextlib.contextmanager
def dns_server(ipv4, ipv6="fd00::11", address="127.0.0.1", port=0):
    calls = []
    def response(data):
        name, kind, end = dns_question(data)
        calls.append((name, kind))
        address = ipaddress.ip_address(ipv4 if kind == 1 else ipv6).packed
        header = data[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0)
        return header + data[12:end] + b"\xc0\x0c" + struct.pack("!HHIH", kind, 1, 0, len(address)) + address
    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            sock.sendto(response(data), self.client_address)
    class TCP(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(5)
            try:
                while True:
                    size = struct.unpack("!H", read_exact(self.request, 2))[0]
                    result = response(read_exact(self.request, size))
                    self.request.sendall(struct.pack("!H", len(result)) + result)
            except (EOFError, OSError):
                return
    udp = UDPServer((address, port), UDP)
    port = udp.server_address[1]
    with serve(udp), serve(TCPServer((address, port), TCP)):
        yield port, calls


@contextlib.contextmanager
def http_server(address="127.0.0.1", port=0):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(3)
            self.request.recv(8192)
            self.request.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\ndirect")
    with serve((TCPServer6 if ":" in address else TCPServer)((address, port), Handler)) as server:
        yield server.server_address[1]


@contextlib.contextmanager
def socks_server(dns_port, http_port, address="127.0.0.1", port=0):
    calls = []
    connections = []
    dns_ports = [dns_port] if isinstance(dns_port, int) else list(dns_port)
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            sock = self.request
            connections.append(sock)
            sock.settimeout(4)
            try:
                version, methods = read_exact(sock, 2)
                if version != 5:
                    return
                read_exact(sock, methods)
                sock.sendall(b"\x05\x00")
                version, command, reserved, kind = read_exact(sock, 4)
                if command != 1:
                    return
                if kind == 1:
                    host = socket.inet_ntop(socket.AF_INET, read_exact(sock, 4))
                elif kind == 4:
                    host = socket.inet_ntop(socket.AF_INET6, read_exact(sock, 16))
                elif kind == 3:
                    host = read_exact(sock, read_exact(sock, 1)[0]).decode("ascii")
                else:
                    return
                port = struct.unpack("!H", read_exact(sock, 2))[0]
                calls.append((host, port))
                # Fixture cannot make any external connection, even if misconfigured.
                if port not in [*dns_ports, http_port]:
                    sock.sendall(b"\x05\x02\x00\x01" + b"\0" * 6)
                    return
                sock.sendall(b"\x05\x00\x00\x01" + b"\0" * 6)
                if port == http_port:
                    sock.recv(8192)
                    sock.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nproxy")
                    return
                with socket.create_connection(("127.0.0.1", port), timeout=3) as upstream:
                    while True:
                        ready, _, _ = select.select([sock, upstream], [], [], 3)
                        if not ready:
                            return
                        for source in ready:
                            block = source.recv(65535)
                            if not block:
                                return
                            (upstream if source is sock else sock).sendall(block)
            except (OSError, EOFError):
                return
    server = TCPServer((address, port), Handler)
    with serve(server):
        try:
            yield server.server_address[1], calls
        finally:
            for connection in connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass


def socks_http(port, domain, destination, payload=None):
    with socket.create_connection(("127.0.0.1", port), timeout=4) as sock:
        sock.settimeout(4)
        sock.sendall(b"\x05\x01\x00")
        if read_exact(sock, 2) != b"\x05\x00":
            raise OSError("SOCKS authentication rejected")
        try:
            address = ipaddress.ip_address(domain)
            host = bytes([1 if address.version == 4 else 4]) + address.packed
        except ValueError:
            name = domain.encode("ascii")
            host = b"\x03" + bytes([len(name)]) + name
        sock.sendall(b"\x05\x01\x00" + host + struct.pack("!H", destination))
        reply = read_exact(sock, 4)
        if reply[1]:
            raise OSError("SOCKS connection rejected")
        size = {1: 4, 4: 16}.get(reply[3])
        if size is None:
            size = read_exact(sock, 1)[0]
        read_exact(sock, size + 2)
        sock.sendall(payload if payload is not None else f"GET / HTTP/1.0\r\nHost: {domain}\r\n\r\n".encode())
        data = b""
        while block := sock.recv(8192):
            data += block
        if b"\r\n\r\n" not in data:
            raise EOFError("connection closed without an HTTP response")
        return data.split(b"\r\n\r\n", 1)[1].decode()
