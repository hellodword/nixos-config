"""Backup selection, cost accounting and public recovery status."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
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
    def test_target_health_preserves_history_across_policy_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = root / "policy.json"
            policy.write_text(json.dumps({"roots": [{"path": "data"}], "checkPartitions": 12}))
            directory = root / "site-backup-primary"
            directory.mkdir()
            now = 2_000_000
            metadata = {"repository": "a" * 64, "scope": "b" * 64}
            backup.atomic_json(directory / "health-scope.json", metadata | {"time": now - 86400})
            for operation, ago in (("backup", 100), ("check", 15 * 86400), ("restore", 200)):
                (directory / (operation + "-success.json")).write_text(json.dumps(
                    metadata | {"time": now - ago, "checkedPartition": 3, "partitions": 12}))
            delivered = metadata | {"id": "checked", "operation": "check", "result": "success",
                                    "deliveredChannels": ["bark"], "finished": now - 15 * 86400}
            backup.atomic_json(directory / "check-notification.json", delivered)
            targets = {"primary": {"policyFile": str(policy)}}
            def report(at=now):
                return health.status(root, targets, at)
            initial = report()
            self.assertEqual(initial["fresh"], 1)
            self.assertEqual(initial["repositories"]["primary"], {
                "backup": {"ageSeconds": 100, "state": "fresh"},
                "check": {"ageSeconds": 15 * 86400, "state": "stale", "partition": 3, "partitions": 12},
                "canaryRestore": {"ageSeconds": 200, "state": "fresh"},
                "maintenance": {"ageSeconds": None, "state": "pending", "dueAt": now + 44 * 86400},
                "notifications": {"check": delivered}, "results": {}})
            policy.write_text(json.dumps({"roots": [{"path": "different-data"}], "checkPartitions": 12}))
            self.assertEqual(report(), initial)
            self.assertEqual(report(at=now + 44 * 86400 + 1)["repositories"]["primary"]["maintenance"]["state"], "stale")
            new_target = health.status(root, {"replacement": {"policyFile": str(policy)}}, now)["repositories"]["replacement"]
            self.assertEqual(new_target["backup"], {"ageSeconds": None, "state": "pending", "dueAt": now + 36 * 3600})
            failed = {"id": "failed", "operation": "backup", "result": "failure", "finished": now}
            backup.record_result(directory, failed)
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "failed")
            completed = {"id": "completed", "operation": "backup", "result": "success", "finished": now + 10}
            backup.record_result(directory, completed)
            backup.atomic_json(directory / "backup-success.json", {"time": now + 10})
            self.assertEqual(report(at=now + 10)["repositories"]["primary"]["backup"]["state"], "fresh")
            manifest = root / "targets.json"
            manifest.write_text(json.dumps(targets))
            output = root / "status.json"
            subprocess.run([sys.executable, health.__file__, "--state-root", str(root),
                            "--targets", str(manifest), "--output", str(output)], check=True, capture_output=True)
            published = json.loads(output.read_text())["repositories"]["primary"]
            self.assertEqual(published["results"]["backup"]["id"], "completed")
            self.assertEqual(published["notifications"]["check"], delivered)
            (directory / "backup-success.json").write_text("interrupted write")
            self.assertEqual(report()["repositories"]["primary"]["backup"]["state"], "unknown")


class DeliveryTest(unittest.TestCase):
    def test_latest_result_survives_offline_delivery_and_concurrent_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            first = {"id": "first", "operation": "backup", "result": "failure", "finished": 1,
                     "phase": "selection-and-backup", "resticExitCode": 11,
                     "error": "Fatal: repository is locked at https://synthetic:credential@fixture.invalid/private?token=hidden"}
            latest = first | {"id": "latest", "result": "success", "finished": 2}
            backup.record_result(state, first)
            offline = SimpleNamespace(stdout=json.dumps({"channels": [{"channel": "bark", "delivered": False}]}))
            with patch.object(notify.subprocess, "run", return_value=offline) as send:
                notify.deliver(state, "host", "repo", ["bark"], "client")
                body = send.call_args.args[0][-1]
                self.assertIn("resticExitCode=11; error=Fatal: repository is locked", body)
                self.assertNotIn("fixture.invalid", body)
                self.assertNotIn("credential@", body)
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


class RunnerReliabilityTest(unittest.TestCase):
    def test_backup_tolerates_exit_3_only_when_snapshot_summary_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "document").write_text("important")
            (source / "transient.wal").write_text("ephemeral")
            state = root / "state"
            state.mkdir(mode=0o700)
            fake_restic = root / "fake-restic.py"
            mode_file = root / "mode"
            fake_restic.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                f"mode = pathlib.Path({str(mode_file)!r}).read_text().strip()\n"
                "if mode == 'partial-with-snapshot':\n"
                f"    pathlib.Path({str(source / 'transient.wal')!r}).unlink(missing_ok=True)\n"
                "    print(json.dumps({'message_type': 'summary', 'snapshot_id': 'abc12345'}))\n"
                "    sys.exit(3)\n"
                "if mode == 'permission-denied-with-snapshot':\n"
                "    print(json.dumps({'message_type': 'error', 'error': {'message': 'open document: permission denied'}}))\n"
                "    print(json.dumps({'message_type': 'summary', 'snapshot_id': 'denied123'}))\n"
                "    sys.exit(3)\n"
                "if mode == 'partial-without-snapshot':\n"
                "    print(json.dumps({'message_type': 'exit_error', 'message': 'vanished before snapshot'}))\n"
                "    sys.exit(3)\n"
                "print(json.dumps({'message_type': 'summary', 'snapshot_id': 'fatal999'}))\n"
                "sys.exit(1)\n"
            )
            fake_restic.chmod(0o755)
            policy = {"host": "fixture", "roots": [
                {"path": "document", "required": True},
                {"path": "transient.wal"},
            ]}
            args = SimpleNamespace(source=source, state=state, restic=str(fake_restic), run_state=None)

            mode_file.write_text("partial-with-snapshot")
            backup.run_operation(args, policy, {"host": "fixture"}, "backup")
            success = backup.read_record(state / "backup-success.json")
            self.assertEqual(success["snapshot"], "abc12345")
            self.assertTrue(success["partialReadWarning"])
            result = backup.read_record(state / "backup-result.json")
            self.assertEqual(result["result"], "success")
            self.assertTrue(result["partialReadWarning"])

            for bad_mode, expected_code in (
                ("permission-denied-with-snapshot", 3),
                ("partial-without-snapshot", 3),
                ("fatal-with-summary", 1),
            ):
                mode_file.write_text(bad_mode)
                previous_success = (state / "backup-success.json").read_bytes()
                with self.assertRaises(backup.ResticError):
                    backup.run_operation(args, policy, {"host": "fixture"}, "backup")
                self.assertEqual((state / "backup-success.json").read_bytes(), previous_success)
                failed = backup.read_record(state / "backup-result.json")
                self.assertEqual(failed["result"], "failure")
                self.assertEqual(failed["resticExitCode"], expected_code)

    def test_recover_locks_unlocks_stale_boot_and_recycled_pid_while_preserving_live_restic(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            lock_id = "a" * 64
            host = backup.socket.gethostname()
            live_pid = os.getpid()
            btime = 2_000_000_000
            pre_boot_iso = datetime.fromtimestamp(btime - 120, tz=timezone.utc).isoformat().replace("+00:00", ".123456789Z")
            post_boot_iso = datetime.fromtimestamp(btime + 120, tz=timezone.utc).isoformat().replace("+00:00", ".123456789Z")
            unlocked = []

            def make_inspector(lock_payload):
                def fake_command(_binary, arguments, _state, **_kwargs):
                    if arguments[-2:] == ["list", "locks"]:
                        return (lock_id + "\n").encode()
                    if arguments[-3:] == ["cat", "lock", lock_id]:
                        return json.dumps(lock_payload).encode()
                    if arguments == ["unlock"]:
                        unlocked.append(True)
                        return None
                    raise AssertionError(arguments)
                return fake_command

            # Lock created before current boot unlocks even if PID currently exists.
            with patch.object(backup, "boot_time", return_value=btime), \
                    patch.object(backup, "process_comm", return_value="restic"), \
                    patch.object(backup, "restic_command", side_effect=make_inspector(
                        {"hostname": host, "pid": live_pid, "time": pre_boot_iso})):
                backup.recover_locks("restic", state)
            self.assertEqual(len(unlocked), 1)

            # Lock created after boot whose PID now belongs to a non-restic process unlocks.
            with patch.object(backup, "boot_time", return_value=btime), \
                    patch.object(backup, "process_comm", return_value="python3"), \
                    patch.object(backup, "restic_command", side_effect=make_inspector(
                        {"hostname": host, "pid": live_pid, "time": post_boot_iso})):
                backup.recover_locks("restic", state)
            self.assertEqual(len(unlocked), 2)

            # Live local restic lock after boot is preserved.
            with patch.object(backup, "boot_time", return_value=btime), \
                    patch.object(backup, "process_comm", return_value="restic"), \
                    patch.object(backup, "restic_command", side_effect=make_inspector(
                        {"hostname": host, "pid": live_pid, "time": post_boot_iso})), \
                    self.assertRaisesRegex(RuntimeError, "live process"):
                backup.recover_locks("restic", state)

    def test_check_honors_target_partitions_and_cache_flag_and_single_maintenance_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "doc").write_text("data")
            state = root / "state"
            state.mkdir(mode=0o700)
            calls = []

            def fake_restic(_binary, arguments, _state, **_kwargs):
                calls.append(list(arguments))
                if arguments[0] == "backup":
                    return {"snapshot_id": "snap0001"}
                return None

            policy = {
                "host": "fixture",
                "roots": [{"path": "doc", "required": True}],
                "checkPartitions": 24,
                "checkWithCache": True,
                "retention": ["--keep-last", "2"],
            }
            args = SimpleNamespace(source=source, state=state, restic="restic", run_state=None)
            with patch.object(backup, "restic", side_effect=fake_restic):
                backup.run_operation(args, policy, {"host": "fixture"}, "check")
                backup.run_operation(args, policy, {"host": "fixture"}, "maintenance")
            self.assertEqual(calls[0], ["check", "--with-cache", "--read-data-subset=1/24"])
            check_calls = [cmd for cmd in calls[1:] if cmd[0] == "check"]
            self.assertEqual(check_calls, [["check", "--with-cache"]])


if __name__ == "__main__":
    unittest.main()
