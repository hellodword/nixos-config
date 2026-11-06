"""Backup scope, cost accounting and public recovery status."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from tests.support import load_script

backup = load_script("backup/runner.py")
health = load_script("backup/health.py")
notify = load_script("backup/notify.py")


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
            def report(source=root, at=None):
                return health.status(root, {"primary": repository}, policy, source, now if at is None else at)
            initial = report()
            self.assertEqual(initial["fresh"], 1)
            self.assertEqual(initial["repositories"]["primary"], {
                "backup": {"ageSeconds": 100, "state": "fresh"},
                "check": {"ageSeconds": 15 * 86400, "state": "stale", "partition": 3, "partitions": 12},
                "canaryRestore": {"ageSeconds": 200, "state": "fresh"},
                "maintenance": {"ageSeconds": None, "state": "pending", "dueAt": now + 45 * 86400}, "results": {}})
            self.assertEqual(report(root / "another-source")["fresh"], 0)
            repository.write_text("s3:replacement\n")
            waiting = report()["repositories"]["primary"]
            self.assertEqual(waiting["backup"], {"ageSeconds": None, "state": "pending", "dueAt": now + 36 * 3600})
            # Repeated observations keep the original deadline across process restarts.
            self.assertEqual(report(at=now + 35 * 3600)["repositories"]["primary"]["backup"], waiting["backup"])
            self.assertEqual(report(at=now + 37 * 3600)["repositories"]["primary"]["backup"]["state"], "stale")
            failed = backup.scope(policy, root, repository.read_bytes()) | {"operation": "backup", "result": "failure", "finished": now}
            backup.record_result(directory, failed)
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "failed")
            backup.atomic_json(directory / "backup-success.json", failed | {"time": now + 10})
            self.assertEqual(report(at=now + 10)["repositories"]["primary"]["backup"]["state"], "fresh")
            repository.write_text("s3:synthetic\n")
            policy.write_text(json.dumps({"roots": [{"path": "different-data"}], "checkPartitions": 12}))
            self.assertEqual(report()["fresh"], 0)
            (directory / "backup-success.json").write_text("interrupted write")
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "unknown")


class DeliveryTest(unittest.TestCase):
    def test_latest_result_survives_offline_delivery_and_concurrent_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            first = {"id": "first", "operation": "backup", "result": "failure", "finished": 1}
            latest = first | {"id": "latest", "result": "success", "finished": 2}
            backup.record_result(state, first)
            offline = SimpleNamespace(stdout=json.dumps({"channels": [{"channel": "bark", "delivered": False}]}))
            with patch.object(notify.subprocess, "run", return_value=offline):
                notify.deliver(state, "host", "repo", ["bark"], "client")
            self.assertEqual(backup.read_record(state / "backup-pending.json")["id"], "first")
            def completed_while_sending(*_args, **_kwargs):
                backup.record_result(state, latest)
                return SimpleNamespace(stdout=json.dumps({"channels": [{"channel": "bark", "delivered": True}]}))
            with patch.object(notify.subprocess, "run", side_effect=completed_while_sending):
                notify.deliver(state, "host", "repo", ["bark"], "client")
            self.assertEqual(backup.read_record(state / "backup-pending.json")["id"], "latest")
            sent = []
            def delivered(command, **_kwargs):
                channel = command[command.index("--channel") + 1]
                sent.append((channel, command[-1]))
                return SimpleNamespace(stdout=json.dumps({"channels": [{"channel": channel, "delivered": True}]}))
            with patch.object(notify.subprocess, "run", side_effect=delivered):
                notify.deliver(state, "host", "repo", ["bark", "secondary"], "client")
                notify.deliver(state, "host", "repo", ["bark", "secondary"], "client")
            self.assertEqual([channel for channel, _ in sent], ["bark", "secondary"])
            self.assertTrue(all("result=success" in body for _, body in sent))
            final = backup.read_record(state / "backup-notification.json")
            self.assertEqual(final["id"], "latest")
            self.assertEqual(final["deliveredChannels"], ["bark", "secondary"])


if __name__ == "__main__":
    unittest.main()
