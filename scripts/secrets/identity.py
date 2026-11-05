#!/usr/bin/env python3
"""Derive and publish SSH/Git files from an isolated OpenPGP public keyring."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

class IdentityError(ValueError):
    """A diagnostic which contains no key material or private configuration."""


def command(arguments, *, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed; inspect the local identity configuration")
    return result.stdout


def fingerprint(value):
    value = str(value).strip().upper()
    if not re.fullmatch(r"(?:[0-9A-F]{40}|[0-9A-F]{64})", value):
        raise IdentityError("Use a complete OpenPGP fingerprint for each declared subkey")
    return value


def purpose_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", value):
        raise IdentityError("SSH purposes use lowercase letters, digits, hyphens and underscores")
    return value


class PublicKeys:
    def __init__(self, home):
        self.home = Path(home)
        self.keys = {}

    def run(self, *arguments, data=None):
        return command(["gpg", "--homedir", str(self.home), "--no-options", "--batch",
                        "--no-autostart", *arguments], data=data)

    def import_keys(self, armored):
        blocks = re.findall(r"-----BEGIN PGP PUBLIC KEY BLOCK-----.*?-----END PGP PUBLIC KEY BLOCK-----",
                            armored, re.DOTALL)
        remaining = armored
        for block in blocks:
            remaining = remaining.replace(block, "", 1)
        if remaining.strip():
            raise IdentityError("gpg.publicKeys contains complete armored OpenPGP public-key blocks")
        if blocks:
            self.run("--import", data=armored)
        self.refresh()

    def refresh(self):
        current = None
        primary = None
        self.keys = {}
        listing = self.run("--with-colons", "--with-subkey-fingerprint", "--with-keygrip", "--list-keys")
        for line in listing.splitlines():
            fields = line.split(":")
            if fields[0] in ("pub", "sub"):
                current = {"kind": fields[0], "keyid": fields[4], "usage": fields[11],
                           "validity": fields[1]}
            elif fields[0] == "fpr" and current is not None:
                current["fingerprint"] = fields[9]
                if current["kind"] == "pub":
                    primary = fields[9]
                current["primary"] = primary
                self.keys[fields[9]] = current
            elif fields[0] == "grp" and current is not None:
                current["keygrip"] = fields[9]

    def select(self, value, usage, label):
        key = self.keys.get(fingerprint(value))
        if not key or key["kind"] != "sub" or usage not in key["usage"] or not key.get("keygrip"):
            raise IdentityError(f"{label}: supply the public certificate containing the selected subkey")
        if key["validity"] in ("r", "e", "d", "i"):
            raise IdentityError(f"{label}: the selected OpenPGP subkey is not currently usable")
        return key

    def ssh(self, key):
        return self.run("--export-ssh-key", key["fingerprint"] + "!").rstrip() + "\n"

    def armored(self):
        return self.run("--armor", "--export") if self.keys else ""


@contextmanager
def public_keys(armored, *, directory=None):
    with tempfile.TemporaryDirectory(prefix="public-keyring-", dir=directory) as temporary:
        keys = PublicKeys(temporary)
        keys.import_keys(armored)
        yield keys


def ssh_filename(purpose, key):
    return f"gpg.{purpose_name(purpose)}.{key['keyid']}.pub"


def derive(document, keys):
    gpg = document.get("gpg", {})
    identities = {}
    public = {}
    for purpose, selected in gpg.get("ssh", {}).items():
        purpose_name(purpose)
        key = keys.select(selected, "a", f"SSH purpose {purpose}")
        name = ssh_filename(purpose, key)
        identities[purpose] = {field: key[field] for field in ("fingerprint", "keyid", "keygrip")}
        identities[purpose]["file"] = name
        public[name] = keys.ssh(key)
    signing = gpg.get("signingKey")
    if signing:
        signing = keys.select(signing, "s", "Git signing")["fingerprint"]
    return {"ssh": identities, "signingKey": signing or None}, public



@contextmanager
def locked(path):
    with path.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def publish(source, runtime, ssh_directory, user):
    account = pwd.getpwnam(user)
    runtime.mkdir(parents=True, exist_ok=True, mode=0o755)
    runtime.chmod(0o755)
    ssh_directory.mkdir(parents=True, exist_ok=True)
    with locked(runtime / ".lock"):
        document = yaml.safe_load(source.read_text())
        with public_keys(document.get("gpg", {}).get("publicKeys", ""), directory=runtime) as keys:
            manifest, public = derive(document, keys)
            files = {
                "public.asc": keys.armored(),
                "ssh.conf": document.get("ssh", {}).get("hosts", ""),
                "git-identity.conf": document.get("git", {}).get("identity", ""),
                "git-signing.conf": ("[user]\n  signingKey = " + manifest["signingKey"] + "!\n"
                                     if manifest["signingKey"] else ""),
                "manifest.json": json.dumps(manifest, sort_keys=True) + "\n",
                **{"keys/" + name: value for name, value in public.items()},
            }
        current = runtime / "current"
        previous = current.resolve() if current.is_symlink() else None
        if previous and all((previous / name).is_file() and (previous / name).read_text() == value
                            for name, value in files.items()):
            # The links can be removed by /etc activation independently of the runtime files.
            generation = previous
        else:
            generation = Path(tempfile.mkdtemp(prefix="generation-", dir=runtime))
        published = generation == previous
        try:
            for name, value in public.items():
                path = ssh_directory / name
                expected = str(current / "keys" / name)
                if os.path.lexists(path) and not (path.is_symlink() and os.readlink(path) == expected):
                    raise IdentityError(f"SSH public-key destination requires manual handover: {path}")
            if not published:
                for name, value in files.items():
                    path = generation / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(value)
                    path.chmod(0o400)
                    os.chown(path, account.pw_uid, account.pw_gid)
                for directory in (generation, generation / "keys"):
                    if directory.is_dir():
                        directory.chmod(0o755)
            for name in public:
                path = ssh_directory / name
                expected = str(current / "keys" / name)
                if path.is_symlink() and os.readlink(path) == expected:
                    continue
                temporary = ssh_directory / (".identity-" + name)
                temporary.unlink(missing_ok=True)
                temporary.symlink_to(expected)
                os.replace(temporary, path)
            if not published:
                temporary = runtime / ".current"
                temporary.unlink(missing_ok=True)
                temporary.symlink_to(generation.name)
                os.replace(temporary, current)
                published = True
            for path in ssh_directory.glob("gpg.*.pub"):
                if (path.name not in public and path.is_symlink()
                        and os.readlink(path) == str(current / "keys" / path.name)):
                    path.unlink()
            for path in runtime.glob("generation-*"):
                if path not in (generation, previous):
                    shutil.rmtree(path)
        finally:
            if not published:
                shutil.rmtree(generation)
    print(f"Published {len(public)} GPG SSH identities and native SSH/Git configuration")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    prepare = commands.add_parser("prepare", help="publish identity files after SOPS decryption")
    prepare.add_argument("--source", type=Path, required=True)
    prepare.add_argument("--runtime", type=Path, required=True)
    prepare.add_argument("--ssh-directory", type=Path, default=Path("/etc/ssh"))
    prepare.add_argument("--user", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        publish(args.source, args.runtime, args.ssh_directory, args.user)
    except IdentityError as error:
        print(str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, KeyError, AttributeError, yaml.YAMLError, RuntimeError,
            subprocess.SubprocessError):
        print("Identity operation failed; inspect the identity document and service permissions.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
