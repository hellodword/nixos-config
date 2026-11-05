"""Backup scope, cost accounting and public recovery status."""
import json
from pathlib import Path
import tempfile
import unittest

from tests.support import load_script

backup = load_script("backup/runner.py")
health = load_script("backup/health.py")


class SelectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "data").mkdir()
        (self.root / "data/keep").write_text("important")

    def test_plan_accounts_for_selected_bytes_and_optional_roots(self):
        for name in ("Cache/blob", "generated/nested/result", "archive/notes"):
            path = self.root / "data" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("contents")
        (self.root / "data/link").symlink_to("/outside/saved-as-link")
        plan = backup.select(self.root, {"roots": [
            {"path": "data", "required": True, "excludeNames": ["Cache"], "excludePaths": ["generated/*"]},
            {"path": "optional-app"},
        ]})
        self.assertEqual(plan, {"paths": ["data/archive/notes", "data/keep", "data/link"],
                                "bytes": len(b"importantcontents"), "missingOptional": ["optional-app"]})
        with self.assertRaises(ValueError):
            backup.select(self.root, {"roots": [{"path": "optional-app", "required": True}]})

    def test_invalid_scope_is_rejected_before_reading_data(self):
        (self.root / "alias").symlink_to(self.root / "data", target_is_directory=True)
        scopes = [[{"path": value}] for value in
                  ("../data", "/data", "data/../data", "", "data//keep", "alias/keep", "absent")]
        scopes.append([{"path": "data"}, {"path": "data/keep"}])
        for roots in scopes:
            with self.subTest(roots=roots), self.assertRaises(ValueError):
                backup.select(self.root, {"roots": roots})


class HealthTest(unittest.TestCase):
    def test_health_follows_repository_source_policy_and_operation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = root / "policy.json"
            policy.write_text(json.dumps({"roots": [{"path": "data"}], "checkPartitions": 12}))
            repository = root / "repository"
            repository.write_text("s3:synthetic\n")
            directory = root / "site-backup-primary"
            directory.mkdir()
            now = 2_000_000
            metadata = backup.scope(policy, root, repository.read_bytes())
            for operation, ago in (("backup", 100), ("check", 15 * 86400), ("restore", 200)):
                (directory / (operation + "-success.json")).write_text(json.dumps(
                    metadata | {"time": now - ago, "checkedPartition": 3, "partitions": 12}))
            def report(source=root):
                return health.status(root, {"primary": repository}, policy, source, now)
            initial = report()
            self.assertEqual(initial["fresh"], 1)
            self.assertEqual(initial["repositories"]["primary"], {
                "backup": {"ageSeconds": 100, "state": "fresh"},
                "check": {"ageSeconds": 15 * 86400, "state": "stale", "partition": 3, "partitions": 12},
                "canaryRestore": {"ageSeconds": 200, "state": "fresh"}})
            self.assertEqual(report(root / "another-source")["fresh"], 0)
            repository.write_text("s3:replacement\n")
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "unknown")
            repository.write_text("s3:synthetic\n")
            policy.write_text(json.dumps({"roots": [{"path": "different-data"}], "checkPartitions": 12}))
            self.assertEqual(report()["fresh"], 0)
            (directory / "backup-success.json").write_text("interrupted write")
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "unknown")


if __name__ == "__main__":
    unittest.main()
