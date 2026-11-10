"""Persistent, immutable snapshots for shared domain rule sets."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def source_key(definition):
    return hashlib.sha256(json.dumps([definition["url"], definition["format"]]).encode()).hexdigest()


def remote_source(definition):
    allowed = {"type", "tag", "format", "url", "initial_path"}
    if set(definition) - allowed or definition.get("format") not in {"binary", "source"}:
        raise ValueError("Shared remote rule sets require type, tag, format, url and initial_path")
    url = urlsplit(definition.get("url", ""))
    if url.scheme not in {"https", "http"} or not url.netloc:
        raise ValueError("Remote rule sets require an HTTP(S) URL")
    if not Path(definition.get("initial_path", "")).is_absolute():
        raise ValueError("Shared remote rule sets require an absolute initial_path")
    return source_key(definition)


def atomic_json(path, value, mode=0o600):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), mode)
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


class Store:
    def __init__(self, root, status):
        self.root, self.status = root, status
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.state = json.loads((root / "state.json").read_text())
        except FileNotFoundError:
            self.state = {"active": None, "pending": None}

    def directory(self, record):
        return self.root / ("generation-" + record["id"])

    def save(self):
        atomic_json(self.root / "state.json", self.state)
        self.publish_status()

    def publish_status(self):
        public = {}
        for name in ("active", "pending"):
            record = self.state.get(name)
            public[name] = {key: record[key] for key in ("id", "created")} if record else None
        public.update({key: self.state[key] for key in ("checked", "result") if key in self.state})
        self.status.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        self.status.parent.chmod(0o755)
        atomic_json(self.status, public, 0o644)

    def due(self, now=None):
        now = time.time() if now is None else now
        return now >= max(self.state.get("lastSuccess", 0) + 86400,
                          self.state.get("lastAttempt", 0) + 3600)

    def snapshot(self, definitions, *, download=False, curl="curl", proxy=None):
        active_paths = paths(self.directory(self.state["active"])) if self.state.get("active") else {}
        with tempfile.TemporaryDirectory(prefix="download-", dir=self.root) as temporary:
            stage = Path(temporary)
            files = {}
            for definition in definitions:
                key = remote_source(definition)
                if key in files:
                    continue
                output = stage / key
                if download:
                    command = [curl, "--fail", "--location", "--silent", "--show-error",
                               "--connect-timeout", "10", "--max-time", "120", "--retry", "2",
                               "--max-filesize", "33554432", "--proto", "=http,https",
                               "--proto-redir", "=http,https", "--output", str(output)]
                    command += ["--proxy", proxy, "--noproxy", ""] if proxy else ["--noproxy", "*"]
                    subprocess.run([*command, definition["url"]], check=True, capture_output=True, timeout=400)
                else:
                    shutil.copyfile(active_paths.get(key, definition["initial_path"]), output)
                files[key] = hashlib.sha256(output.read_bytes()).hexdigest()
            identity = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
            record = {"id": identity, "created": timestamp()}
            destination = self.directory(record)
            if destination.exists():
                return json.loads((destination / "manifest.json").read_text())["record"]
            atomic_json(stage / "manifest.json", {"record": record, "files": files})
            os.rename(stage, destination)
            return record

    def cleanup(self):
        try:
            try:
                committed = json.loads((self.root / "state.json").read_text())
            except FileNotFoundError:
                committed = {}
            retained = {self.directory(record) for name in ("active", "pending") if (record := committed.get(name))}
            for directory in [*self.root.glob("generation-*"), *self.root.glob("download-*")]:
                if directory in retained:
                    continue
                shutil.rmtree(directory)
        except OSError as error:
            print(f"Could not remove unused rule snapshots: {error}", file=sys.stderr)


def paths(directory):
    if directory is None:
        return {}
    manifest = json.loads((directory / "manifest.json").read_text())
    return {key: directory / key for key in manifest["files"]}
