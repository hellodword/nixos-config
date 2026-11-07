"""Declared GPG SSH identities through registration, recovery and rotation."""
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

            def register():
                return subprocess.run(worker + ["register", "--runtime", str(runtime), "--home", str(home)],
                                      capture_output=True, text=True, timeout=60)

            def retire(purpose):
                subprocess.run(["gpg-connect-agent", "--homedir", str(home),
                                f"KEYATTR {keys[purpose]['keygrip']} Use-for-ssh: false", "/bye"],
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
            legacy = fixture / "sshcontrol"
            legacy.write_text(keys["github"]["keygrip"] + "\n")
            (home / "sshcontrol").symlink_to(legacy)
            missing_key = home / "private-keys-v1.d" / (keys["ios"]["keygrip"] + ".key")
            saved_key = fixture / "ios.key"
            missing_key.rename(saved_key)
            unavailable = register()
            self.assertEqual(unavailable.returncode, 1)
            self.assertIn("ios", unavailable.stderr)
            self.assertIn(keys["ios"]["fingerprint"], unavailable.stderr)
            gpg_identity.verify(home, fixture, missing=("ios",))
            saved_key.rename(missing_key)
            recovered = register()
            self.assertEqual(recovered.returncode, 0, recovered.stderr)
            # Declarative sshcontrol links can disappear during Home Manager activation.
            (home / "sshcontrol").unlink()
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
            rotated = register()
            self.assertEqual(rotated.returncode, 0, rotated.stderr)
            gpg_identity.verify(home, fixture, retained=("github", "gitlab"))
            payload = root / "payload"
            payload.write_text("SSH agent protocol signing after identity rotation\n")
            public = public_directory / gpg_identity.public_name("github", keys["next"])
            subprocess.run(["ssh-keygen", "-Y", "sign", "-U", "-f", str(public), "-n", "identity", str(payload)],
                           env=isolated, check=True, capture_output=True)
            signers = root / "allowed-signers"
            signers.write_text("synthetic " + public.read_text())
            subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "synthetic", "-n", "identity", "-s", str(payload) + ".sig"],
                           input=payload.read_bytes(), env=isolated, check=True, capture_output=True)
            previous = fixture / "previous.pub"
            previous.write_text(keys["github"]["public"])
            subprocess.run(["ssh-keygen", "-Y", "sign", "-U", "-f", str(previous), "-n", "identity"],
                           input=b"Previous identity remains available during remote migration\n",
                           env=isolated, check=True, capture_output=True)
            for purpose in ("github", "gitlab"):
                retire(purpose)
            self.assertEqual(register().returncode, 0)
            gpg_identity.verify(home, fixture)
            self.assertEqual(public.stat().st_mode & 0o777, 0o400)


if __name__ == "__main__":
    unittest.main()
