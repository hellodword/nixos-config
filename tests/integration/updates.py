"""Exercise multi-lockfile update candidate preparation and atomic PR fast-forward merge."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tests.support import ROOT


NIX_CI = [sys.executable, str(ROOT / "infra/ci")]


def write_test_manifest(repo_dir):
    nix_dir = repo_dir / "nix"
    nix_dir.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "nix/ci.nix", nix_dir / "ci.nix")
    infra_nix_dir = repo_dir / "infra/nix"
    infra_nix_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "infra/nix/ci.nix", infra_nix_dir / "ci.nix")


class UpdateCandidate(unittest.TestCase):
    def test_rule_snapshots_travel_with_other_updates(self):
        names = ("sing-box-geosite", "sing-box-geoip", "nixpkgs")
        baseline = {
            "version": 7,
            "root": "root",
            "nodes": {
                "root": {"inputs": {name: name for name in names}},
                **{
                    name: {
                        "locked": {
                            "rev": "old",
                            "narHash": "old-hash",
                            "lastModified": 1,
                            "type": "github",
                            "owner": "fixture",
                            "repo": name,
                        },
                        "original": {"type": "github", "owner": "fixture", "repo": name},
                    }
                    for name in names
                },
            },
        }
        for scenario in ("unchanged", "rules", "mixed", "source"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)

                def git(*arguments):
                    return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()

                git("init", "--quiet", "--initial-branch=master")
                git("config", "user.name", "Update fixture")
                git("config", "user.email", "fixture@example.invalid")
                git("config", "commit.gpgsign", "false")
                write_test_manifest(root)
                lock = root / "flake.lock"
                lock.write_text(json.dumps(baseline))
                git("add", "--", "flake.lock", "nix/ci.nix", "infra/nix/ci.nix")
                git("commit", "--quiet", "-m", "fixture")
                base = git("rev-parse", "HEAD")

                candidate = copy.deepcopy(baseline)
                if scenario != "unchanged":
                    for name in names if scenario == "mixed" else names[:2]:
                        candidate["nodes"][name]["locked"].update(
                            rev="new", narHash="new-hash", lastModified=2
                        )
                if scenario == "source":
                    candidate["nodes"][names[0]]["original"]["repo"] = "different-source"
                lock.write_text(json.dumps(candidate))

                state, output = root / "candidate", root / "output"
                subprocess.run(
                    [
                        *NIX_CI,
                        "update",
                        "prepare",
                        "--project-dir",
                        str(root),
                        "--select",
                        json.dumps({"scope": "laptop", "hostName": "laptop2"}),
                        "--state",
                        str(state),
                    ],
                    cwd=root,
                    env=os.environ
                    | {
                        "GITHUB_OUTPUT": str(output),
                        "GITHUB_RUN_ID": "1",
                        "GITHUB_RUN_ATTEMPT": "1",
                    },
                    check=True,
                    capture_output=True,
                    text=True,
                )
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

    def test_multi_lockfile_allowlist_and_sequential_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            upstream, project, next_checkout = (
                work / name for name in ("upstream", "project", "next")
            )

            def git(directory, *arguments):
                return subprocess.check_output(["git", *arguments], cwd=directory, text=True).strip()

            def commit(directory, message):
                git(
                    directory,
                    "-c",
                    "user.name=Update fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--no-gpg-sign",
                    "--quiet",
                    "-m",
                    message,
                )

            def locked_rev(lock_path, name):
                lock = json.loads(lock_path.read_text())
                target = lock["nodes"][lock["root"]]["inputs"][name]
                if isinstance(target, list):
                    node = lock["root"]
                    for part in target:
                        node = lock["nodes"][node]["inputs"][part]
                    return lock["nodes"][node]["locked"]["rev"]
                return lock["nodes"][target]["locked"]["rev"]

            def prepare(directory, scope, idx, *, update_locks=False):
                state = work / f"candidate-{scope}-{idx}"
                output = work / f"output-{scope}-{idx}"
                select_json = json.dumps({
                    "scope": scope,
                    "hostName": "laptop2" if scope == "laptop" else "",
                })
                subprocess.run(
                    [
                        *NIX_CI,
                        "update",
                        "prepare",
                        *(["--update-locks"] if update_locks else []),
                        "--project-dir",
                        str(directory),
                        "--select",
                        select_json,
                        "--state",
                        str(state),
                    ],
                    cwd=directory,
                    env=os.environ
                    | {
                        "GITHUB_OUTPUT": str(output),
                        "GITHUB_RUN_ID": "42",
                        "GITHUB_RUN_ATTEMPT": "1",
                    },
                    check=True,
                    capture_output=True,
                    text=True,
                )
                git(directory, "bundle", "verify", str(state / "candidate.bundle"))
                return (
                    json.loads((state / "update.json").read_text()),
                    dict(line.split("=", 1) for line in output.read_text().splitlines()),
                )

            for directory in (upstream, project):
                directory.mkdir()
                git(directory, "init", "--quiet", "--initial-branch=master")

            (upstream / "flake.nix").write_text("{ outputs = { self }: { lib.revision = 1; }; }\n")
            git(upstream, "add", "--", "flake.nix")
            commit(upstream, "upstream v1")
            rev_v1 = git(upstream, "rev-parse", "HEAD")

            url = json.dumps(f"git+file://{upstream}?ref=master")
            (project / "infra").mkdir()
            (project / "infra/flake.nix").write_text(
                f"{{ inputs.nixpkgs.url = {url}; outputs = {{ self, nixpkgs }}: {{ }}; }}\n"
            )
            (project / "flake.nix").write_text(
                "{\n"
                '  inputs.infra.url = "./infra";\n'
                '  inputs.nixpkgs.follows = "infra/nixpkgs";\n'
                f"  inputs.nixpkgs-remote.url = {url};\n"
                "  outputs = inputs: { };\n"
                "}\n"
            )
            write_test_manifest(project)
            git(project, "add", "--", "flake.nix", "infra/flake.nix", "infra/nix/ci.nix", "nix/ci.nix")
            subprocess.run(
                ["nix", "flake", "lock", "./infra"],
                cwd=project,
                check=True,
                capture_output=True,
                text=True,
            )
            git(project, "add", "-N", "--", "infra/flake.lock")
            subprocess.run(
                ["nix", "flake", "lock"],
                cwd=project,
                check=True,
                capture_output=True,
                text=True,
            )
            git(project, "add", "--", "infra/flake.lock", "flake.lock")
            commit(project, "initial multi-lockfile baseline")

            # Advance upstream to v2.
            (upstream / "flake.nix").write_text("{ outputs = { self }: { lib.revision = 2; }; }\n")
            git(upstream, "add", "--", "flake.nix")
            commit(upstream, "upstream v2")
            rev_v2 = git(upstream, "rev-parse", "HEAD")

            # 1. Remote scope rejects changes to infra/flake.lock or unrelated files.
            (project / "README.md").write_text("unrelated\n")
            rejected = subprocess.run(
                [
                    *NIX_CI,
                    "update",
                    "prepare",
                    "--project-dir",
                    str(project),
                    "--select",
                    '{"scope":"remote","hostName":""}',
                    "--state",
                    str(work / "rejected"),
                ],
                cwd=project,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            (project / "README.md").unlink()

            # 2. Remote update touches only root flake.lock via declarative update.targets.
            (project / "nix/ci.nix").write_text(
                "{ flake, system ? \"x86_64-linux\", select ? {} }:\n"
                "let remote = (select.scope or \"laptop\") == \"remote\"; in {\n"
                "  update = if remote then {\n"
                "    targets = [ { inputs = [ \"nixpkgs-remote\" ]; } ];\n"
                "    allowedLockfiles = [ \"flake.lock\" ];\n"
                "    ignoreOnlyInputs = [];\n"
                "    commitTitle = \"chore: update remote flake inputs\";\n"
                "    branchPrefix = \"automation/flake-update-remote\";\n"
                "  } else {\n"
                "    targets = [\n"
                "      { flake = \"./infra\"; inputs = [ \"nixpkgs\" ]; }\n"
                "      { inputs = [ \"infra\" ]; }\n"
                "    ];\n"
                "    allowedLockfiles = [ \"flake.lock\" \"infra/flake.lock\" ];\n"
                "    ignoreOnlyInputs = [];\n"
                "    commitTitle = \"chore: update laptop flake inputs\";\n"
                "    branchPrefix = \"automation/flake-update-laptop\";\n"
                "  };\n"
                "}\n"
            )
            git(project, "add", "--", "nix/ci.nix")
            commit(project, "declare fixture update targets")

            remote_rec, remote_out = prepare(project, "remote", 1, update_locks=True)
            self.assertEqual(locked_rev(project / "infra/flake.lock", "nixpkgs"), rev_v1)
            self.assertEqual(locked_rev(project / "flake.lock", "nixpkgs-remote"), rev_v2)
            self.assertEqual(remote_rec["lockfiles"], ["flake.lock"])

            # 3. Laptop update starts from remote's merged head and updates BOTH infra/flake.lock and flake.lock.
            git(work, "clone", "--quiet", str(project), str(next_checkout))
            laptop_rec, laptop_out = prepare(next_checkout, "laptop", 2, update_locks=True)
            self.assertEqual(locked_rev(next_checkout / "infra/flake.lock", "nixpkgs"), rev_v2)
            self.assertEqual(locked_rev(next_checkout / "flake.lock", "nixpkgs"), rev_v2)
            self.assertEqual(laptop_rec["base"], remote_rec["head"])
            self.assertEqual(sorted(laptop_rec["lockfiles"]), ["flake.lock", "infra/flake.lock"])
            self.assertNotEqual(remote_rec["branch"], laptop_rec["branch"])
            self.assertNotEqual(remote_out["artifact"], laptop_out["artifact"])

    def test_merge_skips_stale_candidate_and_fast_forwards_matching_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            origin = root / "origin.git"
            repo = root / "repo"
            origin.mkdir()
            repo.mkdir()

            subprocess.run(
                ["git", "init", "--bare", "--quiet", "--initial-branch=master", str(origin)],
                check=True,
            )

            def git(*arguments, cwd=repo):
                return subprocess.check_output(["git", *arguments], cwd=cwd, text=True).strip()

            git("init", "--quiet", "--initial-branch=master")
            git("config", "user.name", "Update fixture")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "commit.gpgsign", "false")
            git("remote", "add", "origin", str(origin))
            (repo / "flake.lock").write_text('{"version": 7}\n')
            git("add", "--", "flake.lock")
            git("commit", "--no-gpg-sign", "--quiet", "-m", "base")
            base = git("rev-parse", "HEAD")
            git("push", "--quiet", "origin", "master")

            (repo / "flake.lock").write_text('{"version": 7, "updated": true}\n')
            git("add", "--", "flake.lock")
            git("commit", "--no-gpg-sign", "--quiet", "-m", "candidate")
            head = git("rev-parse", "HEAD")

            state = root / "state"
            state.mkdir()
            subprocess.run(
                ["git", "bundle", "create", str(state / "candidate.bundle"), "HEAD", "^" + base],
                cwd=repo,
                check=True,
            )
            (state / "update.json").write_text(
                json.dumps({
                    "base": base,
                    "head": head,
                    "scope": "remote",
                    "commitTitle": "chore: update remote flake inputs",
                    "lockfiles": ["flake.lock"],
                    "branch": "automation/flake-update-remote-1-1",
                })
            )

            # Subtest 1: remote master already advanced -> skip cleanly with exit 0.
            bin_dir = root / "bin"
            bin_dir.mkdir()
            calls = root / "gh-calls.log"
            gh = bin_dir / "gh"
            gh.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f'printf "%s\\n" "$*" >> {json.dumps(str(calls))}\n'
                'if [[ "${1:-}" == api && "${2:-}" == repos/owner/repo/git/ref/heads/master ]]; then\n'
                "  printf 'ffffffffffffffffffffffffffffffffffffffff\\n'\n"
                "  exit 0\n"
                "fi\n"
                "exit 99\n"
            )
            gh.chmod(0o755)
            summary = root / "summary.md"
            out_stale = root / "output-stale"
            stale = subprocess.run(
                [*NIX_CI, "update", "merge", "--project-dir", str(repo), "--state", str(state)],
                cwd=repo,
                env=os.environ
                | {
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "GITHUB_REPOSITORY": "owner/repo",
                    "GITHUB_STEP_SUMMARY": str(summary),
                    "GITHUB_OUTPUT": str(out_stale),
                },
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("Master advanced", stale.stdout)
            self.assertIn("Skipped stale remote candidate", summary.read_text())
            self.assertIn("merged=false", out_stale.read_text())
            self.assertEqual(
                calls.read_text().splitlines(),
                ["api repos/owner/repo/git/ref/heads/master --jq .object.sha"],
            )

            # Subtest 2: remote master matches base -> checkout bundle on fresh clone, PR + atomic FF merge.
            fresh_clone = root / "fresh"
            subprocess.run(["git", "clone", "--quiet", str(origin), str(fresh_clone)], check=True)
            calls.unlink()
            gh.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f'printf "%s\\n" "$*" >> {json.dumps(str(calls))}\n'
                'if [[ "${1:-}" == api && "${2:-}" == repos/owner/repo/git/ref/heads/master ]]; then\n'
                f"  git --git-dir={json.dumps(str(origin))} rev-parse refs/heads/master\n"
                "  exit 0\n"
                "fi\n"
                'if [[ "${1:-}" == pr && "${2:-}" == create ]]; then\n'
                "  printf 'https://github.com/owner/repo/pull/7\\n'\n"
                "  exit 0\n"
                "fi\n"
                'if [[ "${1:-}" == api && "${2:-}" == --method && "${3:-}" == PATCH && "${4:-}" == repos/owner/repo/git/refs/heads/master ]]; then\n'
                f"  git --git-dir={json.dumps(str(origin))} update-ref refs/heads/master {head} {base}\n"
                "  printf '{}\\n'\n"
                "  exit 0\n"
                "fi\n"
                'if [[ "${1:-}" == pr && "${2:-}" == view ]]; then\n'
                "  printf 'MERGED\\n'\n"
                "  exit 0\n"
                "fi\n"
                'if [[ "${1:-}" == api && "${2:-}" == --method && "${3:-}" == DELETE ]]; then\n'
                f"  git --git-dir={json.dumps(str(origin))} update-ref -d refs/heads/automation/flake-update-remote-1-1\n"
                "  exit 0\n"
                "fi\n"
                "exit 98\n"
            )
            gh.chmod(0o755)
            out_merged = root / "output-merged"
            summary_merged = root / "summary-merged.md"
            merged = subprocess.run(
                [
                    *NIX_CI,
                    "update",
                    "merge",
                    "--project-dir",
                    str(fresh_clone),
                    "--state",
                    str(state),
                ],
                cwd=fresh_clone,
                env=os.environ
                | {
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "GITHUB_REPOSITORY": "owner/repo",
                    "GITHUB_SERVER_URL": "https://github.com",
                    "GITHUB_RUN_ID": "99",
                    "GITHUB_STEP_SUMMARY": str(summary_merged),
                    "GITHUB_OUTPUT": str(out_merged),
                },
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("Merged https://github.com/owner/repo/pull/7", merged.stdout)
            self.assertIn("merged=true", out_merged.read_text())
            self.assertEqual(
                git("--git-dir=" + str(origin), "rev-parse", "refs/heads/master", cwd=root),
                head,
            )


if __name__ == "__main__":
    unittest.main()
