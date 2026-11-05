"""Exercise independent Restic repositories through backup, failure and restore."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tests.support import ROOT, load_script

backup = load_script("backup/runner.py")


class RepositoryTest(unittest.TestCase):
    def test_independent_repositories_restore_and_failed_check_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            (source / "data").mkdir(parents=True)
            contents = {name: ("value:" + name).encode() for name in ["canary", "# note", "[literal]*?.txt", "with\nnewline", "密码", "-flag"]}
            for name, value in contents.items():
                (source / "data" / name).write_bytes(value)
            (source / "data/Cache").mkdir()
            (source / "data/Cache/invalid").write_text("do not save")
            (source / "data/link").symlink_to("/outside/never-follow")
            (source / "identity").mkdir()
            (source / "identity/secret.key").write_text("synthetic identity")
            (source / "identity/secret.key").chmod(0o600)
            (source / "identity/derived.conf").write_text("generated configuration")
            policy = root / "policy.json"
            policy.write_text(json.dumps({"host": "synthetic-host", "roots": [{"path": "data", "required": True, "excludeNames": ["Cache"]}], "checkPartitions": 2, "canary": {"path": "data/canary", "sha256": backup.hashlib.sha256(contents["canary"]).hexdigest()}}))
            selection = json.loads(policy.read_text())
            selection["roots"].extend([{"path": "identity", "includePaths": ["*.key"]}, {"path": "optional-app"}, {"path": "protected/data"}])
            selection["retention"] = ["--keep-last", "1"]
            policy.write_text(json.dumps(selection))
            script = ROOT / "scripts/backup/runner.py"
            binary = shutil.which("restic")
            env = os.environ | {"RESTIC_PASSWORD": "synthetic-test-password", "RESTIC_CACHE_DIR": str(root / "cache")}
            env.pop("RESTIC_REPOSITORY_FILE", None)
            env.pop("RESTIC_PASSWORD_FILE", None)
            for index in range(3):
                repository = root / f"repo-{index}"
                current = env | {"RESTIC_REPOSITORY": str(repository)}
                subprocess.run([binary, "init"], env=current, check=True, capture_output=True)
                # Existing untagged history belongs to an independently managed retention group.
                historical = subprocess.run([binary, "backup", "--json", "--host", "synthetic-host", "--time", "2024-01-01 00:00:00", "data"], cwd=source, env=current, check=True, capture_output=True)
                historic_id = next(json.loads(line)["snapshot_id"] for line in historical.stdout.splitlines() if json.loads(line).get("message_type") == "summary")
                state = root / f"state-{index}"
                args = ["--policy", str(policy), "--source", str(source), "--state", str(state), "--restic", binary]
                def run(operation, override=None, success=True):
                    result = subprocess.run([shutil.which("python3"), str(script), operation, *args], env=override or current, capture_output=True)
                    self.assertEqual(result.returncode, 0 if success else 1, result.stderr.decode() + ((state / "last-command.log").read_text() if (state / "last-command.log").exists() else ""))
                    return result
                # One unavailable destination must not invalidate the other two.
                if index == 1:
                    run("backup", current | {"RESTIC_REPOSITORY": str(root / "missing-repository")}, success=False)
                    self.assertFalse((state / "backup-success.json").exists())
                run("backup")
                if index == 0:
                    first = json.loads((state / "backup-success.json").read_text())
                    # Changed exact selection still finds the stable host/tag parent.
                    (source / "data/new-file").write_text("new")
                    run("backup")
                    log = (state / "last-command.log").read_text()
                    self.assertIn('"files_unmodified":7', log.replace(" ", ""))
                    # Removing the prior snapshot must not strand future backups.
                    subprocess.run([binary, "forget", first["snapshot"]], env=current, check=True, capture_output=True)
                    run("backup")
                self.assertIn("optional-app", json.loads((state / "backup-success.json").read_text())["missingOptional"])
                before_cleanup = subprocess.check_output([binary, "snapshots", "--json"], env=current)
                run("maintenance", current | {"RESTIC_REPOSITORY": str(root / "missing-repository")}, success=False)
                self.assertEqual(subprocess.check_output([binary, "snapshots", "--json"], env=current), before_cleanup)
                if index == 0:
                    success_before = (state / "backup-success.json").read_bytes()
                    (source / "data/unreadable").write_text("must remain recoverable")
                    (source / "protected").mkdir()
                    (source / "protected/data").write_text("optional does not mean unreadable")
                    for unreadable in (source / "data/unreadable", source / "protected"):
                        mode = unreadable.stat().st_mode
                        unreadable.chmod(0)
                        try:
                            run("maintenance", success=False)
                            self.assertEqual((state / "backup-success.json").read_bytes(), success_before)
                            after_failure = json.loads(subprocess.check_output([binary, "snapshots", "--json"], env=current))
                            self.assertTrue({item["id"] for item in json.loads(before_cleanup)} <= {item["id"] for item in after_failure})
                        finally:
                            unreadable.chmod(mode)
                    (source / "data/unreadable").unlink()
                    shutil.rmtree(source / "protected")
                run("maintenance")
                snapshots = json.loads(subprocess.check_output([binary, "snapshots", "--json"], env=current))
                self.assertTrue(any(item["id"].startswith(historic_id) for item in snapshots))
                self.assertEqual(len([item for item in snapshots if "site:synthetic-host" in item.get("tags", [])]), 1)
                run("restore-test")
                run("check")
                before = (state / "check-success.json").read_bytes()
                self.assertEqual(json.loads(before)["nextPartition"], 2)
                run("check", current | {"RESTIC_REPOSITORY": str(root / "missing-repository")}, success=False)
                self.assertEqual((state / "check-success.json").read_bytes(), before)
                run("check")
                self.assertEqual(json.loads((state / "check-success.json").read_text())["nextPartition"], 1)
                destination = root / f"restore-{index}"
                subprocess.run([binary, "restore", "latest", "--target", str(destination), "--verify"], env=current, check=True, capture_output=True)
                for name, value in contents.items():
                    self.assertEqual((destination / "data" / name).read_bytes(), value)
                self.assertFalse((destination / "data/Cache").exists())
                self.assertEqual(os.readlink(destination / "data/link"), "/outside/never-follow")
                self.assertEqual(sorted(p.name for p in (destination / "identity").iterdir()), ["secret.key"])
                self.assertEqual((destination / "identity/secret.key").read_text(), "synthetic identity")
                self.assertEqual((destination / "identity/secret.key").stat().st_mode & 0o777, 0o600)
                self.assertEqual((state / "last-command.log").stat().st_mode & 0o077, 0)


if __name__ == "__main__":
    unittest.main()
