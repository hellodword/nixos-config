"""A local page for the browser's basic loading and rendering check."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PAGE = """<!doctype html><meta charset="utf-8"><title>Application workspace</title>
<h1>Browser workspace / 浏览器工作区</h1>
<label>Chinese input <input id="message"></label>
<p id="ready"></p><script>document.querySelector('#ready').textContent = 'Page loaded';</script>"""


class Website(BaseHTTPRequestHandler):
    def do_GET(self):
        data = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Website).serve_forever()
