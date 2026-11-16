"""Hold data uploads while forwarding the real REST backend's lock operations."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    marker_lock = threading.Lock()

    def forward(self):
        self.connection.settimeout(10)
        upstream = http.client.HTTPConnection("127.0.0.1", 8001, timeout=30)
        try:
            gate = Path("/run/restic-hold")

            def holding():
                try:
                    return gate.read_text().strip()
                except FileNotFoundError:
                    return None

            operation = holding()
            if self.command == "POST" and "/data/" in self.path and operation is not None:
                with self.marker_lock:
                    entered = Path("/run/restic-held")
                    pending = entered.with_suffix(".pending")
                    pending.write_text(operation)
                    pending.replace(entered)
                deadline = time.monotonic() + 120
                while holding() == operation:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("upload gate was not released: " + operation)
                    # A cancelled upload may still have body bytes queued. The
                    # controller clears the gate after the service has stopped.
                    time.sleep(0.05)
            upstream.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            for key, value in self.headers.items():
                if key.lower() not in ("connection", "transfer-encoding"):
                    upstream.putheader(key, value)
            upstream.endheaders()
            remaining = int(self.headers.get("Content-Length", "0"))
            while remaining:
                block = self.rfile.read(min(65536, remaining))
                if not block:
                    raise ConnectionError("upload client disconnected")
                upstream.send(block)
                remaining -= len(block)
            response = upstream.getresponse()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("connection", "transfer-encoding"):
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while block := response.read(65536):
                    self.wfile.write(block)
        except (OSError, http.client.HTTPException) as error:
            self.log_error("%s", error)
            self.close_connection = True
        finally:
            upstream.close()
            self.close_connection = True

    do_GET = do_HEAD = do_POST = do_DELETE = forward


ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
