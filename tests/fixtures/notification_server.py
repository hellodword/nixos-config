"""Local TLS official-service simulator; all requests use synthetic credentials."""
import argparse
import json
import logging
from pathlib import Path
import socketserver
import ssl
import threading

import h2.config
import h2.connection
import h2.events

lock = threading.Lock()


def reply(path, body, peer):
    with lock:
        state = Path("/run/notification-fixture")
        state.mkdir(exist_ok=True)
        failure = state / "failures"
        remaining = int(failure.read_text()) if failure.exists() else 0
        status = 500 if remaining else 200
        if remaining:
            failure.write_text(str(remaining - 1))
        with (state / "events.jsonl").open("a") as stream:
            stream.write(json.dumps({"path": path, "body": json.loads(body), "peer": peer, "status": status}) + "\n")
        return status, json.dumps({"reason": "InternalServerError"} if remaining else {"errcode": 0, "errmsg": "ok"}).encode()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(30)
        try:
            if self.request.selected_alpn_protocol() == "h2":
                connection = h2.connection.H2Connection(h2.config.H2Configuration(client_side=False, header_encoding="utf-8"))
                connection.initiate_connection()
                self.request.sendall(connection.data_to_send())
                requests = {}
                while chunk := self.request.recv(65536):
                    for event in connection.receive_data(chunk):
                        if isinstance(event, h2.events.RequestReceived):
                            requests[event.stream_id] = [dict(event.headers), bytearray()]
                        elif isinstance(event, h2.events.DataReceived):
                            requests[event.stream_id][1].extend(event.data)
                            connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                        elif isinstance(event, h2.events.StreamEnded):
                            headers, body = requests.pop(event.stream_id)
                            status, content = reply(headers[":path"], body, self.client_address[0])
                            connection.send_headers(event.stream_id, [(":status", str(status)), ("content-type", "application/json")])
                            connection.send_data(event.stream_id, content, end_stream=True)
                    self.request.sendall(connection.data_to_send())
            else:
                request = self.rfile.readline().decode().split()
                if len(request) != 3:
                    return
                headers = {}
                while (line := self.rfile.readline()) != b"\r\n":
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                status, content = reply(request[1], self.rfile.read(int(headers.get("content-length", "0"))), self.client_address[0])
                self.wfile.write(f"HTTP/1.1 {status} Result\r\nContent-Type: application/json\r\nContent-Length: {len(content)}\r\nConnection: close\r\n\r\n".encode() + content)
        except Exception:
            logging.exception("Notification request failed: peer=%s protocol=%s",
                              self.client_address, self.request.selected_alpn_protocol())


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(30)
        try:
            return self.tls.wrap_socket(connection, server_side=True), address
        except OSError:
            logging.exception("Notification TLS handshake failed: peer=%s", address)
            connection.close()
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--address", default="0.0.0.0")
    args = parser.parse_args()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    context.set_alpn_protocols(["h2", "http/1.1"])
    with Server((args.address, 443), Handler) as server:
        server.tls = context
        server.serve_forever()
