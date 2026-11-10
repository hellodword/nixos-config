"""Run a foreground, read-only Nginx share in the configured gVisor runtime."""

import argparse
import csv
import fcntl
import fnmatch
import io
import json
import os
from pathlib import Path
import pwd
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote


def nginx_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def mounts():
    def unescape(value):
        return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)
    entries = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        entries.append((Path(unescape(fields[4])), fields[2], Path(unescape(fields[3]))))
    return sorted(entries, key=lambda entry: len(entry[0].parts), reverse=True)


def backing_path(path, entries):
    # realpath alone cannot resolve an impermanence bind mount to /persist.
    for mount, device, root in entries:
        if path.is_relative_to(mount):
            return device, root / path.relative_to(mount)
    raise ValueError(f"Cannot identify filesystem for {path}")


def selection(raw, settings):
    lexical = Path(os.path.abspath(os.path.expanduser(raw)))
    source = lexical.resolve(strict=True)
    if not source.is_file() and not source.is_dir():
        raise ValueError("The source must be a regular file or directory")
    if any(ord(c) < 32 for c in str(source)):
        raise ValueError("The source path contains control characters")
    entries = mounts()
    device, physical = backing_path(source, entries)
    for name in settings["blockedNames"]:
        if any(fnmatch.fnmatchcase(part, name) for p in (lexical, source, physical) for part in p.parts):
            raise ValueError(f"The source is inside a blocked name: {name}")
    broad = ["/", "/home", "/etc", "/run", "/var", "/nix", settings["home"], settings["persistRoot"]]
    for path in broad:
        if (device, physical) == backing_path(Path(path).resolve(), entries):
            raise ValueError("Choose a specific file or directory within this root")
    denied = []
    for path in settings["blockedPaths"]:
        blocked = Path(path).resolve()
        blocked_device, blocked_physical = backing_path(blocked, entries)
        if device != blocked_device:
            continue
        if physical.is_relative_to(blocked_physical):
            raise ValueError(f"The source is inside a blocked path: {path}")
        if blocked_physical.is_relative_to(physical):
            denied.append(blocked_physical.relative_to(physical).as_posix())
    return source, denied


def configuration(settings, denied):
    patterns = [fnmatch.translate(name).removesuffix(r"\z").removesuffix(r"\Z")
                for name in settings["blockedNames"]]
    rules = [f"location ~ {nginx_quote('(?:^|/)(?:' + '|'.join(patterns) + ')(?:/|$)')} {{ return 404; }}"]
    rules += [f"location ~ {nginx_quote('^/' + re.escape(path) + '(?:/|$)')} {{ return 404; }}"
              for path in denied]
    return """
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 128; }
http {
    access_log off;
    default_type application/octet-stream;
    client_body_temp_path /tmp/body;
    map $uri $disposition { default attachment; ~/$ ""; }
    server {
        listen unix:/socket/backend.sock;
        server_name _;
        root /share;
        disable_symlinks on;
        add_header Content-Disposition $disposition;
        add_header X-Content-Type-Options nosniff always;
        add_header Content-Security-Policy "sandbox allow-downloads" always;
        location / {
            limit_except GET { deny all; }
            # try_files checks symlinks before the autoindex content handler.
            try_files $uri $uri/ =404;
            autoindex on;
            autoindex_localtime off;
        }
        %s
    }
}
""" % "\n        ".join(rules)


def mount_argument(source, destination, readonly=True, recursive=False):
    out = io.StringIO()
    fields = ["type=bind", f"source={source}", f"destination={destination}"]
    if readonly:
        fields.append("readonly")
    if not recursive:
        fields.append("bind-recursive=disabled")
    csv.writer(out, lineterminator="").writerow(fields)
    return out.getvalue()


def share(source, denied, settings):
    runtime = Path("/run/site-httpserver")
    with (runtime / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("A temporary share is already running on this host") from None
        if subprocess.run(["docker", "image", "inspect", settings["image"]],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            subprocess.run(["docker", "load", "--input", settings["imageFile"]], check=True)
        with tempfile.TemporaryDirectory(prefix="share-", dir=runtime) as directory:
            work = Path(directory)
            config = work / "nginx.conf"
            config.write_text(configuration(settings, denied))
            cidfile = work / "container-id"
            socket_directory = runtime / "socket"
            socket = socket_directory / "backend.sock"
            socket.unlink(missing_ok=True)
            target = "/share" if source.is_dir() else f"/share/{source.name}"
            command = [
                "docker", "run", "--cidfile", str(cidfile),
                "--runtime=runsc-files", "--network=none", "--read-only",
                "--cap-drop=ALL", "--security-opt=no-new-privileges",
                "--memory=512m", "--memory-swap=512m", "--pids-limit=128",
                "--user", f"{os.getuid()}:{os.getgid()}",
                "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=1777",
                "--mount", mount_argument(source, target),
                "--mount", mount_argument(config, "/etc/nginx/nginx.conf"),
                "--mount", mount_argument(socket_directory, "/socket", readonly=False),
            ]
            for group in os.getgroups():
                command.extend(["--group-add", str(group)])
            command.append(settings["image"])
            process = None
            try:
                process = subprocess.Popen(command, start_new_session=True)
                deadline = time.monotonic() + 30
                while not socket.exists():
                    if process.poll() is not None:
                        raise RuntimeError("The sharing container failed to start")
                    if time.monotonic() >= deadline:
                        raise RuntimeError("The sharing socket was not ready within 30 seconds")
                    time.sleep(0.1)
                suffix = "/" if source.is_dir() else "/" + quote(source.name)
                print(f"Sharing {source}\nhttps://{settings['hostname']}:{settings['port']}{suffix}", flush=True)
                print("Press Ctrl+C to stop sharing.", file=sys.stderr)
                if process.wait() != 0:
                    raise RuntimeError("The sharing container stopped unexpectedly")
            finally:
                # Fast shutdown also terminates transfers already in progress.
                if cidfile.exists():
                    subprocess.run(["docker", "rm", "--force", cidfile.read_text().strip()],
                                   stdout=subprocess.DEVNULL, check=True)
                if process is not None:
                    process.wait(timeout=15)
                socket.unlink(missing_ok=True)


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    parser = argparse.ArgumentParser(prog="httpserver", description=__doc__)
    parser.add_argument("source", nargs="?", default=".", help="file or directory (default: current directory)")
    args = parser.parse_args(sys.argv[2:])
    if os.getuid() != pwd.getpwnam(settings["user"]).pw_uid:
        parser.error(f"Run as {settings['user']}, the configured sharing user")
    try:
        source, denied = selection(args.source, settings)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        share(source, denied, settings)
    except KeyboardInterrupt:
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"httpserver: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
