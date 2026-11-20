#!/usr/bin/env python3
"""Fetch and validate a certificate bundle before publishing its atomic pair."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request


def check(*args):
    return subprocess.run(["openssl", *args], check=True, capture_output=True, timeout=15).stdout


def refresh(request_file, state, ca_file):
    settings = json.loads(request_file.read_text())
    request = urllib.request.Request(
        settings["url"],
        headers={
            "Authorization": "Bearer " + settings["token"],
            "User-Agent": "site-vps-certificate",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        bundle = json.loads(response.read(1024 * 1024))
    current = state / "current"
    checkend = "0" if not current.exists() else "604800"
    with tempfile.TemporaryDirectory(prefix=".candidate-", dir=state) as temp:
        candidate = Path(temp)
        cert, key = candidate / "tls.crt", candidate / "tls.key"
        cert.write_text(bundle["certificate"])
        key.write_text(bundle["key"])
        cert.chmod(0o600)
        key.chmod(0o600)
        check("x509", "-in", str(cert), "-checkend", checkend, "-noout")
        for name in settings.get("names", [settings["serverName"]]):
            check("verify", "-CAfile", str(ca_file), "-untrusted", str(cert), "-verify_hostname", name, str(cert))
        if check("x509", "-in", str(cert), "-pubkey", "-noout") != check("pkey", "-in", str(key), "-pubout"):
            raise ValueError("certificate and private key do not match")
        identity = hashlib.sha256(cert.read_bytes() + key.read_bytes()).hexdigest()
        if current.is_symlink() and current.readlink() == Path(identity):
            return False
        destination = state / identity
        if not destination.exists():
            shutil.copytree(candidate, destination)
        pending = state / ".current-next"
        pending.unlink(missing_ok=True)
        pending.symlink_to(identity)
        os.replace(pending, current)
        (state / "changed").touch(mode=0o600)
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--ca-file", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        changed = refresh(args.request, args.state, args.ca_file)
    except urllib.error.HTTPError as error:
        error.close()
        parser.exit(1, f"Certificate fetch failed with HTTP {error.code}; the installed bundle remains available.\n")
    except urllib.error.URLError as error:
        parser.exit(1, f"Certificate fetch failed ({error.reason}); the installed bundle remains available.\n")
    except subprocess.CalledProcessError as error:
        lines = error.stderr.decode("utf-8", errors="replace").strip().splitlines()
        detail = lines[-1] if lines else f"openssl exited {error.returncode}"
        parser.exit(1, f"Certificate validation failed ({detail}); the installed bundle remains available.\n")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Certificate refresh failed ({error}); the installed bundle remains available.\n")
    print("Certificate installed" if changed else "Certificate current")


if __name__ == "__main__":
    main()
