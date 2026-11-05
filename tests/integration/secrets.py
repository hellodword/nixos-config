"""Public identity publication and manual GPG agent operations."""
import json
from contextlib import ExitStack
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import unittest

import yaml

from tests.fixtures import gpg_identity

ROOT = Path(__file__).resolve().parents[2]


class DeclaredIdentity(unittest.TestCase):
    def test_identity_publication_signing_and_rotation(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as cleanup:
            root = Path(temporary)
            home = root / "gpg"
            home.mkdir(mode=0o700)
            (home / "gpg-agent.conf").write_text("enable-ssh-support\n")
            cleanup.callback(subprocess.run, ["gpgconf", "--homedir", str(home), "--kill", "all"],
                             capture_output=True, timeout=10)
            fixture = root / "fixture"
            document, keys = gpg_identity.create(home, fixture)
            runtime = root / "published"
            public_directory = root / "ssh"
            worker = ["python3", str(ROOT / "scripts/secrets/identity.py")]

            def publish():
                subprocess.run(worker + ["prepare", "--source", str(fixture / "identity.yaml"),
                                         "--runtime", str(runtime), "--ssh-directory", str(public_directory),
                                         "--user", pwd.getpwuid(os.getuid()).pw_name], check=True, capture_output=True)

            def register(purpose, enabled):
                subprocess.run(["gpg-connect-agent", "--homedir", str(home),
                                f"KEYATTR {keys[purpose]['keygrip']} Use-for-ssh: {enabled}", "/bye"],
                               check=True, capture_output=True)

            publish()
            # Existing files need an explicit handover, including a regular
            # file whose public-key bytes equal the declared certificate.
            public = public_directory / gpg_identity.public_name("github", keys["github"])
            saved = public.read_bytes()
            public.unlink()
            public.write_bytes(saved)
            with self.assertRaises(subprocess.CalledProcessError):
                publish()
            self.assertFalse(public.is_symlink())
            self.assertEqual(public.read_bytes(), saved)
            public.unlink()
            publish()
            gpg_identity.gpg(home, "--import", str(runtime / "current/public.asc"))
            for purpose in gpg_identity.PURPOSES:
                register(purpose, "true")
            gpg_identity.verify(home, fixture)
            socket = subprocess.check_output(["gpgconf", "--homedir", str(home), "--list-dirs", "agent-ssh-socket"], text=True).strip()
            isolated = os.environ | {"GNUPGHOME": str(home), "SSH_AUTH_SOCK": socket,
                                     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(root / "gitconfig")}
            (root / "gitconfig").write_text("[include]\n  path = " + str(runtime / "current/git-identity.conf")
                                           + "\n  path = " + str(runtime / "current/git-signing.conf") + "\n")
            subprocess.run(["git", "init", str(root / "repo")], env=isolated, check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root / "repo"), "-c", "commit.gpgsign=true", "commit", "--allow-empty", "-m", "Synthetic identity"],
                           env=isolated, check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root / "repo"), "verify-commit", "HEAD"], env=isolated, check=True, capture_output=True)
            gpg_identity.rotate(fixture)
            publish()
            register("next", "true")
            register("github", "false")
            register("gitlab", "false")
            gpg_identity.verify(home, fixture)
            payload = root / "payload"
            payload.write_text("SSH agent protocol signing after identity rotation\n")
            public = public_directory / gpg_identity.public_name("github", keys["next"])
            subprocess.run(["ssh-keygen", "-Y", "sign", "-U", "-f", str(public), "-n", "identity", str(payload)],
                           env=isolated, check=True, capture_output=True)
            signers = root / "allowed-signers"
            signers.write_text("synthetic " + public.read_text())
            subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "synthetic", "-n", "identity", "-s", str(payload) + ".sig"],
                           input=payload.read_bytes(), env=isolated, check=True, capture_output=True)
            self.assertEqual(public.stat().st_mode & 0o777, 0o400)


if __name__ == "__main__":
    unittest.main()
