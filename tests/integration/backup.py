"""Exercise independent Restic repositories through backup, failure and restore."""
import json
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import unquote, urlsplit
from types import SimpleNamespace
from unittest.mock import patch

from tests.support import ROOT, load_script

backup = load_script("backup/runner.py")
health = load_script("backup/health.py")


class RestBackend:
    """Expose a synthetic repository over Restic REST with observable reads and locks."""
    def __init__(self, repository):
        self.requests = []
        self.block_data = False
        self.reading = threading.Event()
        self.release = threading.Event()
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def serve(self):
                name = unquote(urlsplit(self.path).path).strip("/")
                path = repository / name
                fixture.requests.append((self.command, name))
                if self.command == "POST":
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(self.rfile.read(int(self.headers["Content-Length"])))
                    self.send_response(200)
                    self.end_headers()
                    return
                if not path.exists():
                    self.send_error(404)
                    return
                if self.command == "DELETE":
                    path.unlink()
                    self.send_response(200)
                    self.end_headers()
                    return
                if name.startswith("data/") and not path.is_dir() and fixture.block_data:
                    fixture.reading.set()
                    fixture.release.wait(30)
                if path.is_dir():
                    # Local repositories shard data packs; REST lists them flat.
                    body = json.dumps([{"name": p.name, "size": p.stat().st_size}
                                       for p in path.rglob("*") if p.is_file()]).encode()
                    content_type = "application/vnd.x.restic.rest.v2"
                else:
                    body = path.read_bytes()
                    content_type = "application/octet-stream"
                code = 200
                if self.headers.get("Range"):
                    start, end = self.headers["Range"].removeprefix("bytes=").split("-")
                    body = body[int(start):int(end) + 1 if end else None]
                    code = 206
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def handle_request(self):
                # The REST backend uses unsharded data URLs; map them to the
                # native filesystem layout without changing the request ledger.
                name = urlsplit(self.path).path
                if name.startswith("/data/") and len(name.removeprefix("/data/")) == 64:
                    identity = name.removeprefix("/data/")
                    self.path = f"/data/{identity[:2]}/{identity}"
                try:
                    self.serve()
                except (BrokenPipeError, ConnectionResetError):
                    pass

            do_GET = do_HEAD = do_POST = do_DELETE = handle_request

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"rest:http://127.0.0.1:{self.server.server_port}/"

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def pause_reads(self):
        self.reading.clear()
        self.release.clear()
        self.block_data = True

    def resume_reads(self):
        self.block_data = False
        self.release.set()

    def data_reads(self):
        return sum(method == "GET" and name.startswith("data/") for method, name in self.requests)


class RepositoryTest(unittest.TestCase):
    def test_repository_policy_survives_restarts_and_manual_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "canary").write_text("recoverable")
            definition = {"host": "fixture", "roots": [{"path": "canary", "required": True}],
                          "canary": {"path": "canary", "sha256": backup.hashlib.sha256(b"recoverable").hexdigest()},
                          "checkPartitions": 2, "retention": ["--keep-last", "2"],
                          "minimumIntervalSeconds": {"check": 7 * 86400, "restore-test": 7 * 86400, "maintenance": 30 * 86400},
                          "schedule": {"timeZone": "Asia/Shanghai", "windows": [
                              {"start": "10:10", "end": "12:00", "maintenance": False},
                              {"start": "21:10", "end": "23:00", "maintenance": True}]}}
            policy = root / "policy.json"
            policy.write_text(json.dumps(definition))
            repo = root / "repository"
            definition["automatic"] = {"backupAttemptsPerWindow": 1, "heavySpacingSeconds": 86400,
                                       "retryIntervalSeconds": {"check": 86400}}
            definition["health"] = {"check": 21 * 86400}
            policy.write_text(json.dumps(definition))
            env = os.environ | {"RESTIC_REPOSITORY": str(repo), "RESTIC_PASSWORD": "synthetic", "RESTIC_CACHE_DIR": str(root / "cache")}
            env.pop("RESTIC_REPOSITORY_FILE", None)
            env.pop("RESTIC_PASSWORD_FILE", None)
            subprocess.run(["restic", "init"], env=env, check=True, capture_output=True)
            state = root / "site-backup-limited"
            clock = [0]

            def at(instant, operation="automatic", force=False):
                clock[0] = datetime.fromisoformat(instant).timestamp()
                # Fresh arguments each time emulate separate systemd invocations.
                args = SimpleNamespace(operation=operation, policy=policy, source=source, state=state,
                                       restic=shutil.which("restic"), force=force, run_state=None, offset_minutes=None)
                return backup.execute(args)

            with patch.dict(os.environ, env, clear=True), patch.object(backup.time, "time", side_effect=lambda: clock[0]), patch.object(backup, "on_ac_power", return_value=True):
                repo.rename(root / "offline")
                with self.assertRaises(RuntimeError):
                    at("2027-03-15T03:00:00+00:00")
                (root / "offline").rename(repo)
                self.assertEqual(at("2027-03-15T03:30:00+00:00"), "backup attempt limit for this window")
                backup.record_result(state, {"operation": "backup", "result": "skipped", "reason": "repository busy"})
                self.assertEqual(at("2027-03-15T03:45:00+00:00"), "backup attempt limit for this window")
                at("2027-03-15T03:46:00+00:00", "backup")
                morning = backup.read_record(state / "backup-success.json")
                # At night backup succeeds. Make the check fail after that success.
                original = backup.run_operation
                def unavailable_check(*args, **kwargs):
                    if args[3] == "check":
                        repo.rename(root / "offline")
                        try:
                            return original(*args, **kwargs)
                        finally:
                            (root / "offline").rename(repo)
                    return original(*args, **kwargs)
                with patch.object(backup, "run_operation", side_effect=unavailable_check), self.assertRaises(RuntimeError):
                    at("2027-03-15T13:30:00+00:00")
                self.assertNotEqual(backup.read_record(state / "backup-success.json")["window"], morning["window"])
                failed = backup.read_record(state / "check-attempt.json")
                at("2027-03-15T13:40:00+00:00")
                self.assertEqual(backup.read_record(state / "check-attempt.json"), failed)
                # Manual service work bypasses automatic spacing, but its attempts
                # still count when the next automatic invocation evaluates work.
                at("2027-03-15T13:45:00+00:00", "restore-test")
                self.assertEqual(at("2027-03-15T13:46:00+00:00", "restore-test"), "recent successful run")
                at("2027-03-15T13:47:00+00:00", "restore-test", force=True)
                # Retain records written by the earlier runner when a target's
                # next configuration includes an additional backup path.
                for record_path in state.glob("*.json"):
                    backup.atomic_json(record_path, backup.read_record(record_path) |
                                       {"repository": "a" * 64, "scope": "b" * 64})
                manual = backup.read_record(state / "restore-test-attempt.json")
                failed = backup.read_record(state / "check-attempt.json")
                evening = backup.read_record(state / "backup-success.json")
                (source / "added.txt").write_text("included in the next backup")
                definition["roots"].append({"path": "added.txt", "required": True})
                policy.write_text(json.dumps(definition))
                at("2027-03-15T13:48:00+00:00")
                self.assertEqual(backup.read_record(state / "backup-success.json"), evening)
                at("2027-03-16T03:00:00+00:00")
                self.assertGreater(backup.read_record(state / "backup-success.json")["time"], failed["finished"])
                at("2027-03-16T13:30:00+00:00")
                self.assertEqual(backup.read_record(state / "restore-test-attempt.json"), manual)
                self.assertEqual(backup.read_record(state / "check-attempt.json"), failed)
                report = health.status(root, {"limited": {"policyFile": str(policy)}}, clock[0])
                self.assertEqual(report["repositories"]["limited"]["automatic"]["maintenance"]["nextEligibleAt"],
                                 manual["started"] + 86400)
                # Never-attempted maintenance takes its turn; the previous check
                # failure cannot starve it. Maintenance performs its own precheck.
                at("2027-03-16T14:00:00+00:00")
                self.assertEqual(backup.read_record(state / "maintenance-result.json")["result"], "success")
                self.assertEqual(backup.read_record(state / "check-attempt.json"), failed)
                at("2027-03-17T14:01:00+00:00")
                progress = backup.read_record(state / "check-success.json")
                self.assertEqual(progress["nextPartition"], 2)
                # A policy edit retains successful recovery points and partition
                # progress, while changing eligibility and health immediately.
                definition["minimumIntervalSeconds"]["check"] = 14 * 86400
                definition["automatic"]["heavySpacingSeconds"] = 2 * 86400
                policy.write_text(json.dumps(definition))
                report = health.status(root, {"limited": {"policyFile": str(policy)}}, clock[0])
                actual = report["repositories"]["limited"]
                self.assertEqual(actual["check"]["state"], "fresh")
                self.assertEqual(actual["check"]["partition"], 1)
                self.assertEqual(actual["automatic"]["check"]["nextEligibleAt"], int(clock[0] + 14 * 86400))
                self.assertEqual(backup.read_record(state / "check-success.json"), progress)
            destination = root / "restored"
            subprocess.run(["restic", "restore", "latest", "--target", str(destination), "--verify"],
                           env=env, check=True, capture_output=True)
            self.assertEqual((destination / "added.txt").read_text(), "included in the next backup")

    def test_remote_checks_and_cancellation_preserve_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for i in range(500):
                directory = source / f"directory-{i}"
                directory.mkdir()
                (directory / "document").write_bytes((f"contents-{i}" * 100).encode())
            repository = root / "repository"
            env = os.environ | {"RESTIC_REPOSITORY": str(repository), "RESTIC_PASSWORD": "synthetic", "RESTIC_CACHE_DIR": str(root / "cache")}
            env.pop("RESTIC_REPOSITORY_FILE", None)
            env.pop("RESTIC_PASSWORD_FILE", None)
            subprocess.run(["restic", "init"], env=env, check=True, capture_output=True)
            subprocess.run(["restic", "backup", "."], cwd=source, env=env, check=True, capture_output=True)
            backend = RestBackend(repository)
            self.addCleanup(backend.close)
            env["RESTIC_REPOSITORY"] = backend.url
            policy = root / "policy.json"
            policy.write_text(json.dumps({"host": "fixture", "roots": [{"path": "directory-0", "required": True}],
                                          "checkPartitions": 1, "recoverStaleLocks": True}))
            state = root / "state"
            command = [shutil.which("python3"), str(ROOT / "scripts/backup/runner.py")]
            options = ["--policy", str(policy), "--source", str(source), "--state", str(state)]

            def run(operation, success=True):
                result = subprocess.run([*command, operation, *options], env=env, capture_output=True, timeout=45)
                self.assertEqual(result.returncode, 0 if success else 1, result.stderr.decode() + (state / "last-command.log").read_text())
                return backup.read_record(state / f"{operation}-result.json")

            run("backup")  # Populate the persistent cache before testing checks.
            subprocess.run(["restic", "check", "--no-cache"], env=env, check=True, capture_output=True)
            uncached = backend.data_reads()
            backend.requests.clear()
            run("check")
            cached = backend.data_reads()
            self.assertGreater(uncached, 500)
            self.assertLess(cached * 20, uncached)
            good = (state / "check-success.json").read_bytes()
            # A warm persistent cache must not hide damaged remote packs.
            pack = next(p for p in (repository / "data").rglob("*") if p.is_file())
            contents = pack.read_bytes()
            pack.chmod(0o600)
            pack.write_bytes(bytes([contents[0] ^ 1]) + contents[1:])
            failed = run("check", success=False)
            self.assertEqual(failed["resticExitCode"], 1)
            self.assertEqual((state / "check-success.json").read_bytes(), good)
            pack.write_bytes(contents)

            for group in (False, True):
                with self.subTest(signal_process_group=group):
                    backend.pause_reads()
                    process = subprocess.Popen([*command, "check", *options], env=env, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, start_new_session=True)
                    try:
                        self.assertTrue(backend.reading.wait(15))
                        self.assertTrue(list((repository / "locks").iterdir()))
                        started = time.monotonic()
                        if group:
                            os.killpg(process.pid, signal.SIGTERM)
                        else:
                            process.terminate()
                        stdout, stderr = process.communicate(timeout=10)
                        self.assertEqual(process.returncode, 130, stdout + stderr)
                        self.assertLess(time.monotonic() - started, 10)
                        self.assertEqual(list((repository / "locks").iterdir()), [])
                        self.assertEqual((state / "check-success.json").read_bytes(), good)
                    finally:
                        backend.resume_reads()
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.communicate()

            # A live exclusive owner is preserved. A killed owner leaves a real
            # remote lock which the next operation may safely remove and retry.
            backend.pause_reads()
            owner = subprocess.Popen(["restic", "check"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.assertTrue(backend.reading.wait(15))
                failed = run("backup", success=False)
                self.assertEqual(failed["resticExitCode"], 11)
                self.assertTrue(list((repository / "locks").iterdir()))
                owner.kill()
                owner.wait()
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait()
                backend.resume_reads()
            run("backup")
            self.assertEqual(list((repository / "locks").iterdir()), [])
            restored = root / "restored"
            subprocess.run(["restic", "restore", "latest", "--target", str(restored), "--verify"], env=env, check=True, capture_output=True)
            self.assertEqual((restored / "directory-0/document").read_bytes(), (source / "directory-0/document").read_bytes())

    def test_window_retries_and_due_maintenance_use_independent_clocks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "canary").write_text("recoverable")
            repository = root / "repo"
            env = os.environ | {"RESTIC_REPOSITORY": str(repository), "RESTIC_PASSWORD": "synthetic", "RESTIC_CACHE_DIR": str(root / "cache"), "TZ": "America/New_York"}
            env.pop("RESTIC_REPOSITORY_FILE", None)
            env.pop("RESTIC_PASSWORD_FILE", None)
            subprocess.run(["restic", "init"], env=env, check=True, capture_output=True)
            policy = {"host": "schedule-fixture", "roots": [{"path": "canary", "required": True}],
                      "canary": {"path": "canary", "sha256": backup.hashlib.sha256(b"recoverable").hexdigest()},
                      "retention": ["--keep-last", "2"], "checkPartitions": 2,
                      "minimumIntervalSeconds": {"check": 7 * 86400, "restore-test": 7 * 86400, "maintenance": 30 * 86400},
                      "schedule": {"timeZone": "Asia/Shanghai", "windows": [
                          {"start": "10:10", "end": "12:00", "maintenance": False},
                          {"start": "21:10", "end": "23:00", "maintenance": True}]}}
            path = root / "policy.json"
            path.write_text(json.dumps(policy))
            args = SimpleNamespace(operation="automatic", policy=path, source=source,
                                   state=root / "state", restic=shutil.which("restic"),
                                   run_state=None, force=False, offset_minutes=5)
            clock = [0]
            power = [False]
            def at(instant):
                clock[0] = datetime.fromisoformat(instant).timestamp()
                try:
                    return backup.execute(args)
                except Exception:
                    log = args.state / "last-command.log"
                    if log.exists():
                        print(log.read_text())
                    raise
            with patch.dict(os.environ, env, clear=True), patch.object(backup.time, "time", side_effect=lambda: clock[0]), patch.object(backup, "on_ac_power", side_effect=lambda: power[0]):
                # The US local date/offset is irrelevant to Shanghai window identity.
                for day in ("2026-07-01", "2026-11-09"):
                    self.assertEqual(at(day + "T02:12:00+00:00"), "outside backup window")
                    at(day + "T03:00:00+00:00")
                    morning = backup.read_record(args.state / "backup-success.json")
                    at(day + "T03:15:00+00:00")
                    self.assertEqual(backup.read_record(args.state / "backup-success.json"), morning)
                    self.assertEqual(at(day + "T05:00:00+00:00"), "outside backup window")
                # A failed evening attempt retries in the same allowed window.
                repository.rename(root / "offline")
                with self.assertRaises(RuntimeError):
                    at("2026-11-09T13:15:00+00:00")
                self.assertEqual(backup.read_record(args.state / "backup-success.json"), morning)
                (root / "offline").rename(repository)
                at("2026-11-09T13:30:00+00:00")
                evening = backup.read_record(args.state / "backup-success.json")
                self.assertNotEqual(evening["window"], morning["window"])
                # AC becoming available permits maintenance without another backup.
                power[0] = True
                at("2026-11-09T13:45:00+00:00")
                self.assertEqual(backup.read_record(args.state / "backup-success.json"), evening)
                for operation in ("check", "restore-test", "maintenance"):
                    self.assertEqual(backup.read_record(args.state / f"{operation}-result.json")["result"], "success")
                successes = {op: backup.read_record(backup.success_path(args.state, op))
                             for op in ("check", "restore-test", "maintenance")}
                (source / "added.txt").write_text("newly selected data")
                policy["roots"].append({"path": "added.txt", "required": True})
                path.write_text(json.dumps(policy))
                at("2026-11-11T13:45:00+00:00")
                for operation, previous in successes.items():
                    self.assertEqual(backup.read_record(backup.success_path(args.state, operation)), previous)
                at("2026-11-16T13:45:00+00:00")
                checked = backup.read_record(args.state / "check-success.json")
                self.assertEqual((checked["time"], checked["checkedPartition"]), (clock[0], 2))
                self.assertEqual(backup.read_record(args.state / "restore-success.json")["time"], clock[0])
                self.assertEqual(backup.read_record(args.state / "maintenance-success.json"), successes["maintenance"])
                policy["minimumIntervalSeconds"]["check"] = 0
                path.write_text(json.dumps(policy))
                # Once a running check crosses the end, later due phases wait.
                (args.state / "restore-success.json").unlink()
                original = backup.run_operation
                def cross_boundary(*values, **kwargs):
                    result = original(*values, **kwargs)
                    clock[0] = datetime.fromisoformat("2026-11-16T15:01:00+00:00").timestamp()
                    return result
                restored = backup.read_record(args.state / "restore-test-result.json")
                with patch.object(backup, "run_operation", side_effect=cross_boundary):
                    at("2026-11-16T14:59:00+00:00")
                self.assertEqual(backup.read_record(args.state / "restore-test-result.json"), restored)
                # If the monthly preflight check finishes after the window,
                # leave pruning for the next evening without repeating backup.
                policy["minimumIntervalSeconds"]["check"] = 7 * 86400
                path.write_text(json.dumps(policy))
                clock[0] = datetime.fromisoformat("2026-12-10T03:00:00+00:00").timestamp()
                metadata = {"host": policy["host"]}
                backup.run_operation(args, policy, metadata, "check")
                maintained = backup.read_record(args.state / "maintenance-success.json")
                original_restic = backup.restic
                def finish_preflight(binary, arguments, *values, **kwargs):
                    result = original_restic(binary, arguments, *values, **kwargs)
                    if arguments == ["check"]:
                        clock[0] = datetime.fromisoformat("2026-12-10T15:01:00+00:00").timestamp()
                    return result
                with patch.object(backup, "restic", side_effect=finish_preflight):
                    at("2026-12-10T14:59:00+00:00")
                self.assertEqual(backup.read_record(args.state / "maintenance-success.json"), maintained)
                self.assertEqual(backup.read_record(args.state / "maintenance-result.json")["result"], "skipped")
                at("2026-12-11T13:30:00+00:00")
                self.assertGreater(backup.read_record(args.state / "maintenance-success.json")["time"], maintained["time"])
            destination = root / "restored"
            subprocess.run(["restic", "restore", "latest", "--target", str(destination), "--verify"], env=env, check=True, capture_output=True)
            self.assertEqual((destination / "canary").read_text(), "recoverable")
            self.assertEqual((destination / "added.txt").read_text(), "newly selected data")

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
