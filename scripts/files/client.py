"""Issue, export and revoke device identities for the file service."""

import argparse
import fcntl
import getpass
import hashlib
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import tempfile
import uuid


STATE = Path("/var/lib/site-files")
AUTHORITY = STATE / "private/clients"


def openssl(*args, data=None):
    return subprocess.run(["openssl", *map(str, args)], input=data, check=True,
                          stdout=subprocess.PIPE).stdout


def fingerprint(cert):
    return hashlib.sha256(openssl("x509", "-in", cert, "-outform", "DER")).hexdigest().upper()


def initialize():
    if AUTHORITY.exists():
        return
    with tempfile.TemporaryDirectory(dir=STATE / "private", prefix="client-ca-") as temporary:
        work = Path(temporary) / "authority"
        work.mkdir()
        (work / "devices").mkdir()
        openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                "-keyout", work / "ca.key", "-out", work / "ca.crt", "-days", "7300",
                "-subj", "/CN=File service device CA",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        (work / "authorized").touch()
        work.rename(AUTHORITY)


def publish():
    devices = sorted((AUTHORITY / "devices").iterdir())
    allowed = [fingerprint(device / "certificate.crt") for device in devices
               if not (device / "revoked").exists()]
    temporary = AUTHORITY / "authorized.new"
    temporary.write_text("".join(value + "\n" for value in allowed))
    temporary.replace(AUTHORITY / "authorized")
    # A restart closes active TLS connections as well as reloading the allowlist.
    subprocess.run(["systemctl", "try-restart", "site-files-web.service"], check=True)


def issue(name):
    destination = AUTHORITY / "devices" / name
    if destination.exists():
        raise ValueError("This device name already exists; use a new name for a replacement identity")
    with tempfile.TemporaryDirectory(dir=AUTHORITY, prefix="issue-") as temporary:
        work = Path(temporary) / name
        work.mkdir()
        openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                "-keyout", work / "key.pem", "-out", work / "request.csr", "-subj", f"/CN={name}")
        extension = work / "extensions"
        extension.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                             "extendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n")
        openssl("x509", "-req", "-in", work / "request.csr", "-CA", AUTHORITY / "ca.crt",
                "-CAkey", AUTHORITY / "ca.key", "-set_serial", "0x" + secrets.token_hex(16),
                "-days", "3650", "-extfile", extension, "-out", work / "certificate.crt")
        (work / "request.csr").unlink()
        extension.unlink()
        work.rename(destination)
    publish()
    print(f"Issued {name}: {fingerprint(destination / 'certificate.crt')}")


def payload(kind, name, **values):
    identifier = str(uuid.uuid4())
    return {"PayloadType": kind, "PayloadVersion": 1, "PayloadUUID": identifier,
            "PayloadIdentifier": "site.files." + identifier, "PayloadDisplayName": name, **values}


def export(name, output_dir):
    device = AUTHORITY / "devices" / name
    if (device / "revoked").exists():
        raise ValueError("This identity has been revoked; issue a replacement under a new name")
    password = getpass.getpass("PKCS#12 export password: ")
    if not password or "\n" in password or "\r" in password:
        raise ValueError("Use a nonempty, single-line export password")
    if password != getpass.getpass("Repeat password: "):
        raise ValueError("Passwords do not match")
    # Export using OpenSSL 3 modern PKCS#12 defaults (PBES2 AES-256-CBC and
    # HMAC-SHA256); the password is never embedded in the configuration profile.
    identity = openssl("pkcs12", "-export", "-in", device / "certificate.crt",
                       "-inkey", device / "key.pem", "-certfile", AUTHORITY / "ca.crt",
                       "-name", name, "-iter", "100000", "-passout", "stdin",
                       data=(password + "\n").encode())
    ca = openssl("x509", "-in", STATE / "ca.crt", "-outform", "DER")
    profile = payload("Configuration", f"File service — {name}", PayloadContent=[
        payload("com.apple.security.root", "File sharing server CA", PayloadContent=ca),
        payload("com.apple.security.pkcs12", name, PayloadContent=identity),
    ])
    owner = int(os.environ.get("SUDO_UID", "0")), int(os.environ.get("SUDO_GID", "0"))
    output_dir.mkdir(mode=0o700)
    for filename, content in (("server-ca.cer", ca), (f"{name}.p12", identity),
                              (f"{name}.mobileconfig", plistlib.dumps(profile))):
        with open(os.open(output_dir / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as handle:
            handle.write(content)
            os.fchown(handle.fileno(), *owner)
    os.chown(output_dir, *owner)
    print(f"Exported {output_dir}")


def main():
    parser = argparse.ArgumentParser(prog="site-files-client", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init", help="initialize the device CA (also run by the service)")
    commands.add_parser("list", help="list device status, certificate expiry and SHA-256")
    for command in ("issue", "export", "revoke"):
        sub = commands.add_parser(command)
        sub.add_argument("name", help="device name: letters, numbers, dot, underscore or hyphen")
        if command == "export":
            sub.add_argument("--output-dir", required=True, type=Path, help="new directory for iOS, Android and Windows certificate files")
    args = parser.parse_args()
    if hasattr(args, "name") and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", args.name):
        parser.error("Use a device name starting with a letter or number, at most 64 characters")
    if os.geteuid() != 0:
        parser.error("Run site-files-client with sudo")
    os.umask(0o077)
    try:
        (STATE / "private").mkdir(mode=0o700, parents=True, exist_ok=True)
        with (STATE / "private/client.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            initialize()
            if args.command == "issue":
                issue(args.name)
            elif args.command == "export":
                export(args.name, args.output_dir)
            elif args.command == "revoke":
                device = AUTHORITY / "devices" / args.name
                (device / "revoked").touch()
                publish()
                print(f"Revoked {args.name}; HTTPS connections closed")
            elif args.command == "list":
                for device in sorted((AUTHORITY / "devices").iterdir()):
                    status = "revoked" if (device / "revoked").exists() else "enabled"
                    expiry = openssl("x509", "-in", device / "certificate.crt", "-noout", "-enddate").decode().strip()
                    print(f"{device.name}\t{status}\t{expiry}\t{fingerprint(device / 'certificate.crt')}")
    except (ValueError, OSError, EOFError, subprocess.SubprocessError) as error:
        print(f"site-files-client: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
