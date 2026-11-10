"""Prepare native Dufs and Samba credentials from systemd credentials."""

import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    samba_config = sys.argv[1]
    credentials = Path(os.environ["CREDENTIALS_DIRECTORY"])
    for role, access in (("admin", "/:rw"), ("guest", "/guest:rw")):
        password = (credentials / role).read_text().removesuffix("\n")
        if not password or any(c in password for c in "\r\n\0"):
            raise ValueError(f"{role}: supply a nonempty single-line password")
        # Dufs accepts crypt SHA-512 hashes; raw passwords stay out of its config.
        digest = subprocess.check_output(
            ["openssl", "passwd", "-6", "-stdin"], input=password + "\n", text=True
        ).strip()
        subprocess.run(
            ["smbpasswd", "-c", samba_config, "-s", "-a", f"site-files-{role}"],
            input=f"{password}\n{password}\n", text=True, check=True,
        )
        output = Path(f"/run/site-files-auth/{role}.json")
        temporary = output.with_suffix(".new")
        temporary.write_text(json.dumps({"auth": [f"{role}:{digest}@{access}"]}))
        temporary.chmod(0o600)
        temporary.replace(output)


if __name__ == "__main__":
    main()
