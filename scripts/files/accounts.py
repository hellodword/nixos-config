"""Prepare Copyparty and Samba accounts from systemd credentials."""

import os
from pathlib import Path
import re
import secrets
import subprocess
import sys


def write_private(path, text):
    temporary = path.with_suffix(".new")
    temporary.write_text(text)
    temporary.chmod(0o600)
    temporary.replace(path)


def main():
    samba_config, state_directory = sys.argv[1:]
    state = Path(state_directory)
    credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
    salt_file = state / "accounts/salt"
    if not salt_file.exists():
        write_private(salt_file, secrets.token_urlsafe(24))
    salt = salt_file.read_text()
    accounts = []
    for role in ("admin", "user"):
        password = (credentials / role).read_text().removesuffix("\n")
        if (not password or password != password.strip()
                or any(c in password for c in "\r\n\0")
                or len(f"{role}:{password}") > 255):
            raise ValueError(
                f"{role}: supply a single-line password without surrounding whitespace, "
                f"at most {254 - len(role)} characters"
            )
        # With --usernames, Copyparty hashes username:password together.
        output = subprocess.check_output(
            ["copyparty", "--ah-alg", "scrypt", "--ah-salt", salt,
             "--ah-gen", "-", "--no-ansi"],
            input=f"{role}:{password}\n", text=True,
        )
        hashes = re.findall(r"^\+[A-Za-z0-9_-]{32}$", output, re.MULTILINE)
        if len(hashes) != 1:
            raise RuntimeError("Copyparty did not return an account hash")
        accounts.append(f"  {role}: {hashes[0]}\n")
        subprocess.run(
            ["smbpasswd", "-c", samba_config, "-s", "-a", f"site-files-{role}"],
            input=f"{password}\n{password}\n", text=True, check=True,
        )
    config = f"[global]\n  ah-alg: scrypt\n  ah-salt: {salt}\n\n[accounts]\n" + "".join(accounts)
    config_file = state / "accounts/copyparty.conf"
    if not config_file.exists() or config_file.read_text() != config:
        # The browser is stopped by systemd before this unit restarts. Native
        # sessions survive ordinary restarts; changing credentials revokes them.
        for suffix in ("", "-wal", "-shm"):
            (state / f"browser/sessions.db{suffix}").unlink(missing_ok=True)
        write_private(config_file, config)


if __name__ == "__main__":
    main()
