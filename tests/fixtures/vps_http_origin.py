"""HTTP, WebSocket and port probes for the VPS deployment scenario."""

import base64
import hashlib
import http.server
import json
import socket
import socketserver
import threading


class Application(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            key = self.headers["Sec-WebSocket-Key"]
            digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            frame = self.rfile.read(2)
            assert frame[0] == 0x81 and frame[1] & 0x80
            size = frame[1] & 0x7F
            assert size < 126
            mask = self.rfile.read(4)
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(self.rfile.read(size)))
            self.wfile.write(bytes([0x81, len(payload)]) + payload)
            self.wfile.flush()
            return
        self.reply()

    def do_POST(self):
        self.reply()

    def reply(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        response = json.dumps({
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
            "body": body.decode(),
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class IPv6HTTPServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        connection.sendto(data, self.client_address)


class IPv6UDPServer(socketserver.UDPServer):
    address_family = socket.AF_INET6


if __name__ == "__main__":
    # IPv4 TCP 443 belongs to the real HAProxy/Nginx service. These listeners
    # exercise the other transports covered by the source-address policy.
    servers = [
        http.server.ThreadingHTTPServer(("127.0.0.1", 8080), Application),
        IPv6HTTPServer(("2001:db8:1::11", 443), Application),
        socketserver.UDPServer(("192.0.2.11", 443), Echo),
        IPv6UDPServer(("2001:db8:1::11", 443), Echo),
    ]
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    servers[0].serve_forever()
