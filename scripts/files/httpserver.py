"""Run a foreground, read-only Nginx share in the configured gVisor runtime."""

import argparse
import base64
import csv
import fcntl
import fnmatch
import hashlib
import io
import ipaddress
import json
import mimetypes
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote


PROFILE_TYPE = "application/x-apple-aspen-config"
mimetypes.add_type(PROFILE_TYPE, ".mobileconfig")


def nginx_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def mounts(mountinfo=Path("/proc/self/mountinfo")):
    def unescape(value):
        return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)
    entries = []
    for line in reversed(mountinfo.read_text().splitlines()):
        fields = line.split()
        entries.append((Path(unescape(fields[4])), fields[2], Path(unescape(fields[3]))))
    return sorted(entries, key=lambda entry: len(entry[0].parts), reverse=True)


def safe_resolve(path):
    try:
        return path.resolve()
    except PermissionError:
        if path.parent == path:
            return path
        return safe_resolve(path.parent) / path.name


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
        blocked = safe_resolve(Path(os.path.abspath(os.path.expanduser(path))))
        blocked_device, blocked_physical = backing_path(blocked, entries)
        if device != blocked_device:
            continue
        if physical.is_relative_to(blocked_physical):
            raise ValueError(f"The source is inside a blocked path: {path}")
        if blocked_physical.is_relative_to(physical):
            denied.append(blocked_physical.relative_to(physical).as_posix())
    return source, denied


def login_page(settings, source, grouped_code):
    profile_url = "/" + quote(source.name, safe="") if source.is_file() and source.suffix.lower() == ".mobileconfig" else ""
    return (Path(settings["loginPage"]).read_text()
            .replace("@PROFILE_URL@", profile_url)
            .replace("@GROUPED_CODE@", "true" if grouped_code else "false"))


def configuration(settings, denied, source, code, session, grouped_code):
    patterns = [fnmatch.translate(name).removesuffix(r"\z").removesuffix(r"\Z")
                for name in settings["blockedNames"]]
    rules = [f"location ~ {nginx_quote('(?:^|/)(?:' + '|'.join(patterns) + ')(?:/|$)')} {{ return 404; }}"]
    rules += [f"location ~ {nginx_quote('^/' + re.escape(path) + '(?:/|$)')} {{ return 404; }}"
              for path in denied]
    auth_maps = auth_locations = guard = ""
    if code is not None:
        page = login_page(settings, source, grouped_code)
        script = re.search(r"<script>(.*?)</script>", page, re.S)[1]
        digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
        auth_maps = f"""
    map $http_x_share_session $share_authorized {{
        default 0;
        ~^{session}$ 1;
    }}
    map $http_x_share_code $login_file {{
        default /denied;
        ~^{code.encode().hex()}$ /accepted;
    }}
    map $login_file $login_cookie {{
        default "";
        /accepted "site_share={session}; Path=/; Secure; HttpOnly; SameSite=Lax";
    }}
    limit_req_zone $http_x_forwarded_for zone=login:1m rate=1r/s;
"""
        guard = 'if ($share_authorized = 0) { return 401; }'
        auth_locations = f"""
        error_page 401 =200 @login;
        location @login {{
            root /login;
            add_header Cache-Control "no-store" always;
            add_header Content-Security-Policy "default-src 'none'; script-src 'sha256-{digest}'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" always;
            try_files /index.html =404;
        }}
        location = /_share/login {{
            limit_except POST {{ deny all; }}
            limit_req zone=login burst=5 nodelay;
            limit_req_status 429;
            root /login;
            default_type text/plain;
            # A valid static target rejects POST after access/limit checks.
            error_page 405 = @accepted;
            try_files $login_file =403;
        }}
        location @accepted {{
            add_header Set-Cookie $login_cookie;
            add_header Cache-Control "no-store" always;
            return 204;
        }}
"""
    single = ""
    if source.is_file():
        content_type = mimetypes.guess_type(source.name)[0] or "application/octet-stream"
        filename = re.sub(r"[^A-Za-z0-9_.-]", "_", source.name)
        disposition = nginx_quote(f'inline; filename="{filename}"; filename*=UTF-8\'\'{quote(source.name, safe="")}')
        for path in ("/", "/" + source.name):
            single += f"""
        location = {nginx_quote(path)} {{
            {guard}
            limit_except GET {{ deny all; }}
            try_files /item =404;
            types {{ }}
            default_type {content_type};
            add_header Content-Disposition {disposition};
            add_header X-Content-Type-Options nosniff always;
            add_header Content-Security-Policy $file_csp always;
            add_header Cache-Control "no-store" always;
        }}
"""
    listing = "return 404;" if source.is_file() else "try_files $uri $uri/ =404; autoindex on; autoindex_localtime off;"
    return """
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 128; }
http {
    log_format files escape=json
        '{"time":"$time_iso8601","port":%d,"client":"$http_x_forwarded_for",'
        '"method":"$request_method","url":"$request_uri","path":"$uri","status":$status,'
        '"request_bytes":$request_length,"response_bytes":$bytes_sent,"seconds":$request_time}';
    access_log /dev/stdout files;
    include /etc/nginx/mime.types;
    types { %s mobileconfig; }
    default_type application/octet-stream;
    client_body_temp_path /tmp/body;
    # HTML and SVG need isolation; PDFs and profiles use native browser handling.
    map $sent_http_content_type $file_csp {
        default "sandbox allow-downloads";
        application/pdf "";
        %s "";
    }
    %s
    server {
        listen unix:/socket/backend.sock;
        server_name _;
        root /share;
        disable_symlinks on;
        add_header X-Content-Type-Options nosniff always;
        add_header Content-Security-Policy $file_csp always;
        add_header Cache-Control "no-store" always;
        %s
        %s
        location / {
            %s
            limit_except GET { deny all; }
            # try_files checks symlinks before the autoindex content handler.
            %s
        }
        %s
    }
}
""" % (settings["port"], PROFILE_TYPE, PROFILE_TYPE, auth_maps, auth_locations, single, guard, listing, "\n        ".join(rules))


def lan_addresses():
    links = json.loads(subprocess.check_output(["ip", "-j", "-d", "link", "show"]))
    by_name = {link["ifname"]: link for link in links}
    by_index = {link["ifindex"]: link for link in links}

    def physical(link, visited):
        name = link["ifname"]
        if name in visited:
            return False
        if Path(f"/sys/class/net/{name}/device").exists():
            return True
        kind = link.get("linkinfo", {}).get("info_kind")
        visited = visited | {name}
        if kind == "vlan":
            parent = by_index.get(link.get("link_index")) or by_name.get(link.get("link"))
            return parent is not None and physical(parent, visited)
        if kind in ("bridge", "bond"):
            return any(physical(member, visited) for member in links
                       if member.get("master") in (name, link["ifindex"]))
        return False

    addresses = []
    for interface in json.loads(subprocess.check_output(["ip", "-j", "address", "show", "up"])):
        link = by_name.get(interface["ifname"])
        if not link or link.get("operstate") not in ("UP", "UNKNOWN") or not physical(link, set()):
            continue
        for item in interface.get("addr_info", []):
            address = ipaddress.ip_address(item["local"])
            if item["scope"] != "global" or item.get("tentative") or item.get("deprecated"):
                continue
            if not address.is_loopback and not address.is_link_local:
                addresses.append((interface["ifname"], str(address)))
    return sorted(set(addresses))


def certificate_description(label, der):
    details = subprocess.check_output(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-enddate"], input=der).decode().strip()
    digest = hashlib.sha256(der).hexdigest().upper()
    print(f"{label}\n{details}\nSHA-256: {':'.join(digest[i:i + 2] for i in range(0, len(digest), 2))}", flush=True)


def describe_share(source, settings, code):
    ca_file = Path("/var/lib/site-files/ca.crt")
    context = ssl.create_default_context(cafile=ca_file)
    # Inspect the certificate actually served by 8444, independently of its SAN.
    context.check_hostname = False
    with socket.create_connection(("127.0.0.1", settings["port"]), timeout=10) as connection:
        with context.wrap_socket(connection, server_hostname="localhost") as tls:
            der = tls.getpeercert(binary_form=True)
            names = tls.getpeercert().get("subjectAltName", ())
    print(f"Sharing {source}", flush=True)
    certificate_description("8444 server certificate — compare in the browser before entering the code:", der)
    certificate_description("Server CA — trust when installing:", ssl.PEM_cert_to_DER_cert(ca_file.read_text()))
    addresses = lan_addresses()
    if not addresses:
        print("No active LAN interface address; showing localhost.", file=sys.stderr)
        addresses = [("local", "localhost")]
    for interface, address in addresses:
        covered = ("DNS", address) in names if address == "localhost" else any(
            kind == "IP Address" and ipaddress.ip_address(value) == ipaddress.ip_address(address)
            for kind, value in names)
        host = f"[{address}]" if ":" in address else address
        url = f"https://{host}:{settings['port']}/"
        print(f"\n{interface}: {url}", flush=True)
        if not covered:
            print(f"SAN missing: {address}. Add it to files.certificateNames in SOPS, deploy, then run sudo site-files-certificate.", file=sys.stderr)
        subprocess.run(["qrencode", "--type=ANSIUTF8", "--", url], check=True)
    if code is not None:
        print(f"\nAccess code: {code}", flush=True)


def mount_argument(source, destination, readonly=True, recursive=False):
    out = io.StringIO()
    fields = ["type=bind", f"source={source}", f"destination={destination}"]
    if readonly:
        fields.append("readonly")
    if not recursive:
        fields.append("bind-recursive=disabled")
    csv.writer(out, lineterminator="").writerow(fields)
    return out.getvalue()


def share(source, denied, settings, code, grouped_code):
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
            config.write_text(configuration(settings, denied, source, code, secrets.token_hex(32), grouped_code))
            config.chmod(0o600)
            login = work / "login"
            login.mkdir()
            (login / "index.html").write_text(login_page(settings, source, grouped_code))
            (login / "accepted").touch()
            cidfile = work / "container-id"
            socket_directory = runtime / "socket"
            socket = socket_directory / "backend.sock"
            socket.unlink(missing_ok=True)
            target = "/share" if source.is_dir() else "/share/item"
            command = [
                "docker", "run", "--cidfile", str(cidfile),
                "--runtime=runsc-files", "--network=none", "--read-only",
                "--cap-drop=ALL", "--security-opt=no-new-privileges",
                "--memory=512m", "--memory-swap=512m", "--pids-limit=128",
                "--user", f"{os.getuid()}:{os.getgid()}",
                "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=1777",
                "--mount", mount_argument(source, target),
                "--mount", mount_argument(config, "/etc/nginx/nginx.conf"),
                "--mount", mount_argument(login, "/login"),
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
                describe_share(source, settings, code)
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
    access = parser.add_mutually_exclusive_group()
    access.add_argument("--code", help="require this access code for the current share")
    access.add_argument("--random-code", action="store_true", help="generate a 12-character access code displayed as XXXX-XXXX-XXXX")
    args = parser.parse_args(sys.argv[2:])
    code = args.code
    if args.random_code:
        raw = "".join(secrets.choice("23456789ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(12))
        code = "-".join(raw[start:start + 4] for start in range(0, 12, 4))
    if code is not None and (not code or len(code.encode()) > 256 or any(ord(c) < 32 for c in code)):
        parser.error("Use a nonempty access code, at most 256 UTF-8 bytes, without control characters")
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
        share(source, denied, settings, code, args.random_code)
    except KeyboardInterrupt:
        return 0
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"httpserver: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
