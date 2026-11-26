#!/usr/bin/env python3
"""Serve fixed-channel Apprise notifications inside the isolated container."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import sys
import threading
from urllib.parse import urlsplit

from apprise import (
    Apprise,
    AppriseAsset,
    AppriseConfig,
    NotificationManager,
    NotifyFormat,
    NotifyType,
    PersistentStoreMode,
    URLBase,
)
import yaml

ALLOWED_SCHEMAS = frozenset({"bark", "wecombot", "wechat", "dingtalk", "feishu"})
ALLOWED_FIELDS = frozenset({"body", "title", "tag", "tags", "type", "format", "template"})
TYPES = {item.value: item for item in NotifyType}
FORMATS = {item.value: item.value for item in NotifyFormat}
MAX_BODY_BYTES = 8192
TOKEN_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,31}$")


def check_channel_entries(entries, allowed_types):
    literal_asset = AppriseAsset(
        plugin_paths=[],
        storage_mode=PersistentStoreMode.MEMORY,
        allow_templates=False,
    )
    for entry in entries:
        if isinstance(entry, str):
            pass
        elif isinstance(entry, dict) and entry:
            if sum(1 for key in entry if isinstance(key, str) and "://" in key) != 1:
                raise ValueError("each Apprise channel mapping must specify exactly one URL")
        else:
            raise ValueError("each Apprise channel entry must be a URL string or single-URL mapping")
        config = AppriseConfig(asset=literal_asset)
        snippet = yaml.safe_dump({"urls": [entry]}, allow_unicode=True)
        if not config.add_config(snippet, format="yaml", recursion=0, insecure_includes=False):
            raise ValueError("could not parse Apprise channel entry")
        probe = Apprise(asset=literal_asset)
        probe.add(config)
        if any(not server.enabled or not isinstance(server, allowed_types) for server in probe):
            raise ValueError("channel scheme is outside the allowed notification services")
        if not len(probe):
            raise ValueError("channel entry could not be loaded by an allowed notification service")


def build_apprise(asset, config_yaml):
    config = AppriseConfig(asset=asset)
    if not config.add_config(config_yaml, format="yaml", recursion=0, insecure_includes=False):
        raise RuntimeError("could not parse notification configuration")
    instance = Apprise(asset=asset)
    instance.add(config)
    if not len(instance) or any(not server.enabled for server in instance):
        raise RuntimeError("notification configuration contains disabled or empty services")
    return instance


def load_configuration(channels_path):
    if not hasattr(URLBase, "redirects"):
        raise RuntimeError("Apprise URLBase.redirects attribute is unavailable")
    URLBase.redirects = False
    manager = NotificationManager()
    manager.enable_only(*sorted(ALLOWED_SCHEMAS))
    allowed_types = tuple(plugin for plugin in manager.plugins() if plugin.enabled)
    extra = yaml.safe_load(channels_path.read_text()) or {}
    if (
        not isinstance(extra, dict)
        or set(extra) - {"urls", "version"}
        or extra.get("version", 1) != 1
        or not isinstance(extra.get("urls", []), list)
    ):
        raise ValueError("additional channels must be native Apprise YAML containing a urls list")
    # Channel addresses and credentials are literal configuration, never caller templates.
    if "${" in yaml.safe_dump(extra):
        raise ValueError("channel credentials and addresses must be literal")
    urls = extra.get("urls", [])
    check_channel_entries(urls, allowed_types)
    config = {
        "template": [{"group": "bark"}, {"sound": ""}],
        "urls": [
            {
                "bark://bark:8080/local?group=${GROUP}&sound=${SOUND}&image=no&timeout=15": [
                    {"tag": "bark"}
                ],
            },
            *urls,
        ],
    }
    config_yaml = yaml.safe_dump(config, allow_unicode=True)
    asset = AppriseAsset(
        plugin_paths=[],
        storage_mode=PersistentStoreMode.MEMORY,
        allow_templates=True,
    )
    build_apprise(asset, config_yaml)
    return asset, config_yaml


def parse_request(raw):
    payload = json.loads(raw.decode("utf-8"))
    if not isinstance(payload, dict) or (set(payload) - ALLOWED_FIELDS):
        raise ValueError("unsupported notification payload fields")
    body = payload.get("body")
    title = payload.get("title", "")
    if not isinstance(body, str) or not body.strip() or not isinstance(title, str):
        raise ValueError("notification body and optional title must be strings")
    raw_tag = payload.get("tag", payload.get("tags"))
    if isinstance(raw_tag, str) and raw_tag.strip():
        tags = raw_tag.strip()
    elif isinstance(raw_tag, list) and raw_tag and all(isinstance(t, str) and t.strip() for t in raw_tag):
        tags = [t.strip() for t in raw_tag]
    else:
        raise ValueError("specify at least one configured channel tag")
    notify_type = payload.get("type", "info")
    body_format = payload.get("format", "text")
    if notify_type not in TYPES or body_format not in FORMATS:
        raise ValueError("invalid notification type or format")
    template = payload.get("template") or {}
    if not isinstance(template, dict):
        raise ValueError("template must be a key-value object")
    for key, value in template.items():
        if (not isinstance(key, str) or not TOKEN_NAME.fullmatch(key)
                or not isinstance(value, str) or any(ord(c) < 32 for c in value)):
            raise ValueError("invalid template token")
    return body, title, TYPES[notify_type], FORMATS[body_format], tags, template


class NotificationServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, asset, config_yaml):
        super().__init__(address, Handler)
        self.asset = asset
        self.config_yaml = config_yaml
        self.slots = threading.BoundedSemaphore(16)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def respond(self, status, body):
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        self.respond(404, {"error": "not found"})

    def do_HEAD(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        if urlsplit(self.path).path != "/notify/local":
            self.respond(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.respond(400, {"error": "invalid content length"})
            return
        if length <= 0:
            self.respond(400, {"error": "empty request body"})
            return
        if length > MAX_BODY_BYTES:
            self.respond(413, {"error": "request body too large"})
            return
        raw = self.rfile.read(length)
        try:
            body, title, notify_type, body_format, tags, template = parse_request(raw)
        except (UnicodeDecodeError, ValueError):
            self.respond(400, {"error": "invalid notification payload"})
            return
        with self.server.slots:
            instance = build_apprise(self.server.asset, self.server.config_yaml)
            matched = list(instance.find(tag=tags, template=template))
            delivered = bool(matched) and bool(
                instance.notify(
                    body=body,
                    title=title,
                    notify_type=notify_type,
                    body_format=body_format,
                    tag=tags,
                    template=template,
                )
            )
        self.respond(200 if delivered else 424, {"delivered": delivered})


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channels", type=Path, default=Path("/run/credentials/channels.yaml"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    asset, config_yaml = load_configuration(args.channels)
    server = NotificationServer((args.host, args.port), asset, config_yaml)

    def stop(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
