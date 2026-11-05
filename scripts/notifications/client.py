#!/usr/bin/env python3
"""Send through the local Apprise API socket; output only channel delivery results."""
import argparse
import http.client
import json
import signal
import socket
import sys
import time

SOCKET = "/run/site-notifications/send.sock"


def deadline(_signal, _frame):
    raise TimeoutError("notification request deadline")


class LocalHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=30)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def send(channel, title, body, *, group="bark", sound="", socket_path=SOCKET):
    payload = json.dumps({"title": title, "body": body, "tag": channel, "format": "text",
                          "template": {"group": group, "sound": sound}}, ensure_ascii=False).encode()
    status = None
    for attempt in range(1, 4):
        connection = LocalHTTP(socket_path)
        previous_handler = signal.signal(signal.SIGALRM, deadline)
        signal.setitimer(signal.ITIMER_REAL, 30)
        try:
            connection.request("POST", "/notify/local", payload,
                               {"Content-Type": "application/json", "Accept": "application/json"})
            response = connection.getresponse()
            status = response.status
            response.read(65536)
            if status == 200:
                return {"channel": channel, "delivered": True, "attempts": attempt}
            if status in (400, 401, 403, 404, 413):
                break
        except (OSError, http.client.HTTPException):
            status = None
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
            connection.close()
        if attempt < 3:
            time.sleep(attempt)
    return {"channel": channel, "delivered": False, "attempts": attempt, "httpStatus": status}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=SOCKET)
    sub = parser.add_subparsers(dest="command", required=True)
    bark = sub.add_parser("bark", help="BODY | TITLE BODY | GROUP TITLE BODY [SOUND]")
    bark.add_argument("message", nargs="+")
    notify = sub.add_parser("send")
    notify.add_argument("--channel", action="append", required=True)
    notify.add_argument("--title", required=True)
    notify.add_argument("--group", default="system")
    notify.add_argument("body")
    args = parser.parse_args()
    sound = ""
    if args.command == "bark":
        values = args.message
        if not 1 <= len(values) <= 4:
            parser.error("bark accepts one to four message arguments")
        group, title, body = "bark", "bark", values[-1]
        if len(values) == 2:
            group = title = values[0]
        elif len(values) >= 3:
            group, title, body = values[:3]
            sound = values[3] if len(values) == 4 else ""
        channels = ["bark"]
    else:
        channels, title, body, group = args.channel, args.title, args.body, args.group
    results = [send(channel, title, body, group=group, sound=sound, socket_path=args.socket)
               for channel in dict.fromkeys(channels)]
    print(json.dumps({"channels": results}, ensure_ascii=False))
    return 0 if all(item["delivered"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
