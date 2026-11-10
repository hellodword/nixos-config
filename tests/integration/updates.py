"""Exercise update candidate decisions in disposable Git repositories."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tests.support import ROOT


class UpdateCandidate(unittest.TestCase):
    def test_rule_snapshots_travel_with_other_updates(self):
        names = ("sing-box-geosite", "sing-box-geoip", "nixpkgs")
        baseline = {"version": 7, "root": "root", "nodes": {
            "root": {"inputs": {name: name for name in names}},
            **{name: {"locked": {"rev": "old", "narHash": "old-hash", "lastModified": 1,
                                "type": "github", "owner": "fixture", "repo": name},
                      "original": {"type": "github", "owner": "fixture", "repo": name}}
               for name in names}}}
        for scenario in ("unchanged", "rules", "mixed", "source"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                def git(*arguments):
                    return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()
                git("init", "--quiet", "--initial-branch=main")
                git("config", "user.name", "Update fixture")
                git("config", "user.email", "fixture@example.invalid")
                git("config", "commit.gpgsign", "false")
                lock = root / "flake.lock"
                lock.write_text(json.dumps(baseline))
                git("add", "--", "flake.lock")
                git("commit", "--quiet", "-m", "fixture")
                base = git("rev-parse", "HEAD")
                candidate = copy.deepcopy(baseline)
                if scenario != "unchanged":
                    for name in names if scenario == "mixed" else names[:2]:
                        candidate["nodes"][name]["locked"].update(rev="new", narHash="new-hash", lastModified=2)
                if scenario == "source":
                    candidate["nodes"][names[0]]["original"]["repo"] = "different-source"
                lock.write_text(json.dumps(candidate))
                state, output = root / "candidate", root / "output"
                subprocess.run([sys.executable, str(ROOT / ".github/ci/update.py"), "prepare", "--state", str(state)],
                    cwd=root, env=os.environ | {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1"},
                    check=True, capture_output=True, text=True)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                if scenario in {"mixed", "source"}:
                    self.assertEqual(values["changed"], "true")
                    self.assertEqual(values["sha"], git("rev-parse", "HEAD"))
                    self.assertEqual(json.loads(git("show", "HEAD:flake.lock")), candidate)
                    git("bundle", "verify", str(state / "candidate.bundle"))
                    self.assertEqual(json.loads((state / "update.json").read_text())["base"], base)
                else:
                    self.assertEqual(values, {"changed": "false"})
                    self.assertEqual(git("rev-parse", "HEAD"), base)
                    self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
