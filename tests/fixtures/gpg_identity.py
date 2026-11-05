"""Synthetic OpenPGP identities for declarative SSH/Git configuration and desktop SSH/Git flows."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import yaml


PURPOSES = ("github", "gitlab", "mainland", "vps", "ios")


def gpg(home, *arguments, data=None):
    return subprocess.run(["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback",
                           "--passphrase", "", *arguments], input=data, text=True, check=True,
                          capture_output=True, timeout=30).stdout


def created(home, *arguments):
    output = gpg(home, "--status-fd", "1", *arguments)
    selected = next(line.split()[-1] for line in output.splitlines() if line.startswith("[GNUPG:] KEY_CREATED "))
    listing = gpg(home, "--with-colons", "--with-keygrip", "--list-keys", selected)
    result = None
    for line in listing.splitlines():
        fields = line.split(":")
        if fields[0] == "fpr" and fields[9] == selected:
            result = {"fingerprint": selected, "keyid": selected[-16:]}
        elif fields[0] == "grp" and result is not None:
            result["keygrip"] = fields[9]
            return result
    raise RuntimeError("Synthetic key generation did not return a keygrip")


def public_name(purpose, key):
    return f"gpg.{purpose}.{key['keyid']}.pub"


def create(home, directory):
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    master = created(home, "--quick-generate-key", "Identity Fixture <identity@example.invalid>", "ed25519", "cert", "0")
    keys = {purpose: created(home, "--quick-add-key", master["fingerprint"], "ed25519", "auth", "0")
            for purpose in PURPOSES[:-1]}
    keys["signing"] = created(home, "--quick-add-key", master["fingerprint"], "ed25519", "sign", "0")
    keys["next"] = created(home, "--quick-add-key", master["fingerprint"], "ed25519", "auth", "0")
    ios = created(home, "--quick-generate-key", "Additional Fixture <ios@example.invalid>", "ed25519", "cert", "0")
    keys["ios"] = created(home, "--quick-add-key", ios["fingerprint"], "ed25519", "auth", "0")
    local = created(home, "--quick-generate-key", "Local Fixture <local@example.invalid>", "ed25519", "cert", "0")
    keys["local"] = created(home, "--quick-add-key", local["fingerprint"], "ed25519", "auth", "0")
    for purpose, key in keys.items():
        if purpose != "signing":
            key["public"] = gpg(home, "--export-ssh-key", key["fingerprint"] + "!")
    declared = gpg(home, "--armor", "--export", master["fingerprint"])
    extra = gpg(home, "--armor", "--export", ios["fingerprint"])
    hosts = "Host fixture\n  HostName baseline.example\n\n"
    for purpose in ("github", "gitlab"):
        hosts += (f"Host fixture-{purpose}\n  HostName localhost\n  User desktop\n"
                  f"  IdentityFile /etc/ssh/{public_name(purpose, keys[purpose])}\n"
                  "  IdentitiesOnly yes\n  BatchMode yes\n  StrictHostKeyChecking accept-new\n\n")
    hosts += (f"Host fixture-local\n  HostName localhost\n  User desktop\n"
              f"  IdentityFile {directory}/local.pub\n  IdentitiesOnly yes\n"
              "  BatchMode yes\n  StrictHostKeyChecking accept-new\n")
    document = {"gpg": {"publicKeys": declared + extra,
                         "ssh": {purpose: keys[purpose]["fingerprint"] for purpose in PURPOSES},
                         "signingKey": keys["signing"]["fingerprint"]},
                "ssh": {"hosts": hosts},
                "git": {"identity": "[user]\n  name = Identity Fixture\n  email = identity@example.invalid\n"}}
    (directory / "identity.yaml").write_text(yaml.safe_dump(document, sort_keys=False))
    (directory / "additional.asc").write_text(extra)
    (directory / "initial.asc").write_text(declared)
    (directory / "local.pub").write_text(keys["local"]["public"])
    (directory / "metadata.json").write_text(json.dumps(keys))
    (directory / "ownertrust").write_text(gpg(home, "--export-ownertrust"))
    subprocess.run(["gpg-connect-agent", "--homedir", str(home),
                    f"KEYATTR {keys['local']['keygrip']} Use-for-ssh: true", "/bye"],
                   check=True, capture_output=True)
    return document, keys


def rotate(directory):
    document = yaml.safe_load((directory / "identity.yaml").read_text())
    keys = json.loads((directory / "metadata.json").read_text())
    document["gpg"]["ssh"]["github"] = keys["next"]["fingerprint"]
    del document["gpg"]["ssh"]["gitlab"]
    document["ssh"]["hosts"] = document["ssh"]["hosts"].replace(
        public_name("github", keys["github"]), public_name("github", keys["next"]))
    (directory / "identity.yaml").write_text(yaml.safe_dump(document, sort_keys=False))


def verify(home, directory):
    document = yaml.safe_load((directory / "identity.yaml").read_text())
    keys = json.loads((directory / "metadata.json").read_text())
    desired = set(document["gpg"]["ssh"].values()) | {keys["local"]["fingerprint"]}
    expected = {tuple(key["public"].split()[:2]) for key in keys.values() if key["fingerprint"] in desired}
    socket = subprocess.check_output(["gpgconf", "--homedir", str(home), "--list-dirs", "agent-ssh-socket"], text=True).strip()
    offered = subprocess.check_output(["ssh-add", "-L"], env=os.environ | {"SSH_AUTH_SOCK": socket}, text=True)
    actual = {tuple(line.split()[:2]) for line in offered.splitlines()}
    assert actual == expected, f"Agent identities: {len(expected - actual)} awaiting registration, {len(actual - expected)} awaiting retirement"
    trust = lambda value: sorted(line for line in value.splitlines() if line and not line.startswith("#"))
    assert trust(gpg(home, "--export-ownertrust")) == trust((directory / "ownertrust").read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "rotate", "verify"))
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home() / ".gnupg")
    args = parser.parse_args()
    os.umask(0o077)
    if args.operation == "create":
        _, keys = create(args.home, args.directory)
        ssh = Path.home() / ".ssh"
        ssh.mkdir(exist_ok=True, mode=0o700)
        (ssh / "authorized_keys").write_text("".join(key["public"] for key in keys.values() if "public" in key))
    elif args.operation == "rotate":
        rotate(args.directory)
    else:
        verify(args.home, args.directory)


if __name__ == "__main__":
    main()
