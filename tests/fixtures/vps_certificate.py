"""Authenticated certificate endpoint backed by the public VM TLS fixtures."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import ssl
import sys

cert, key = map(Path, sys.argv[1:])
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        node = self.path.removeprefix('/')
        if self.headers.get('Authorization') != f'Bearer example-{node}-certificate-replace':
            self.send_error(403)
            return
        if Path('/run/certificate-unavailable').exists():
            self.send_error(503)
            return
        body = json.dumps({'certificate': cert.read_text(), 'key': key.read_text()}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
server = HTTPServer(('0.0.0.0', 8443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
