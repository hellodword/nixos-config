#!/usr/bin/env python3
"""Prepare multi-lockfile update candidates and atomically fast-forward verified PRs."""

import copy
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.parse import urlparse

try:
    from .evaluate import sanitized_nixpkgs_env
except ImportError:
    from evaluate import sanitized_nixpkgs_env


def run(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def default_system():
    return "x86_64-linux"


def nix_string_literal(value):
    return json.dumps(value, ensure_ascii=False).replace("${", r"\${")


def load_update_policy(project_dir, manifest_rel="nix/ci.nix", select_obj=None, system=None):
    project_dir = Path(project_dir).resolve()
    select_obj = select_obj or {}
    system = system or default_system()
    manifest_path = project_dir / manifest_rel
    if not manifest_path.exists():
        raise RuntimeError(f"CI manifest not found: {manifest_path}")
    scheme = "git+file://" if (project_dir / ".git").exists() else "path:"
    project_str = nix_string_literal(str(project_dir))
    scheme_str = nix_string_literal(scheme)
    manifest_str = nix_string_literal(str(manifest_rel))
    select_str = nix_string_literal(json.dumps(select_obj, ensure_ascii=False))
    system_str = nix_string_literal(system)
    expr = (
        f"let"
        f" projectDir = {project_str};"
        f" flake = builtins.getFlake ({scheme_str} + projectDir);"
        f" in (import (projectDir + \"/\" + {manifest_str}) {{"
        f"   inherit flake;"
        f"   system = {system_str};"
        f"   select = builtins.fromJSON {select_str};"
        f" }}).update"
    )
    with sanitized_nixpkgs_env() as eval_env:
        policy = json.loads(
            run(
                ["nix", "eval", "--no-update-lock-file", "--impure", "--json", "--expr", expr],
                cwd=project_dir,
                env=eval_env,
            )
        )
    if not policy:
        raise RuntimeError(f"Manifest {manifest_rel} does not define an update policy")
    return policy


def needs_candidate(before, after, ignore_only_inputs):
    """Return True when lockfile changes include anything beyond ignored snapshot revisions."""
    if not ignore_only_inputs:
        return after != before
    normalized = copy.deepcopy(after)
    before_root_inputs = before.get("nodes", {}).get(before.get("root"), {}).get("inputs", {})
    after_root_inputs = after.get("nodes", {}).get(after.get("root"), {}).get("inputs", {})
    for name in ignore_only_inputs:
        old_node = before_root_inputs.get(name)
        new_node = after_root_inputs.get(name)
        if not isinstance(old_node, str) or old_node != new_node:
            continue
        old_lock = before["nodes"].get(old_node, {}).get("locked", {})
        new_lock = normalized["nodes"].get(new_node, {}).get("locked", {})
        for field in ("rev", "narHash", "lastModified", "revCount"):
            if field in old_lock:
                new_lock[field] = old_lock[field]
            else:
                new_lock.pop(field, None)
    return normalized != before


def write_github_outputs(**values):
    if path := os.environ.get("GITHUB_OUTPUT"):
        with Path(path).open("a") as stream:
            for name, value in values.items():
                stream.write(f"{name}={value}\n")


def prepare(*, project_dir, manifest_rel="nix/ci.nix", select_obj=None, state, system=None):
    project_dir = Path(project_dir).resolve()
    state = Path(state).resolve()
    select_obj = select_obj or {}
    policy = load_update_policy(project_dir, manifest_rel, select_obj, system)
    allowed = list(policy["allowedLockfiles"])
    ignore_only = list(policy.get("ignoreOnlyInputs") or [])
    commit_title = policy["commitTitle"]
    branch_prefix = policy["branchPrefix"]

    changed = run(["git", "diff", "--name-only", "HEAD"], cwd=project_dir).splitlines()
    untracked = run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=project_dir,
    ).splitlines()
    all_touched = sorted(dict.fromkeys([*changed, *untracked]))

    if not all_touched:
        write_github_outputs(changed="false")
        print("Tracked inputs are current.", flush=True)
        return {"changed": False}

    disallowed = [path for path in all_touched if path not in allowed]
    if disallowed:
        raise RuntimeError(
            f"Modified paths outside update.allowedLockfiles ({allowed}): {disallowed}"
        )

    substantive = False
    for rel_path in changed:
        before_raw = run(["git", "show", f"HEAD:{rel_path}"], cwd=project_dir)
        before = json.loads(before_raw)
        after = json.loads((project_dir / rel_path).read_text())
        if needs_candidate(before, after, ignore_only if rel_path == "flake.lock" else []):
            substantive = True
    if untracked:
        substantive = True

    if not substantive:
        write_github_outputs(changed="false")
        print(
            "Only ignored snapshot revisions changed; skipping candidate creation.",
            flush=True,
        )
        return {"changed": False}

    state.mkdir(parents=True, exist_ok=True)
    base = run(["git", "rev-parse", "HEAD"], cwd=project_dir)
    subprocess.run(["git", "add", "--", *all_touched], cwd=project_dir, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=github-actions[bot]",
            "-c",
            "user.email=41898282+github-actions[bot]@users.noreply.github.com",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--no-gpg-sign",
            "-m",
            commit_title,
        ],
        cwd=project_dir,
        check=True,
    )
    head = run(["git", "rev-parse", "HEAD"], cwd=project_dir)
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    run_attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    scope_label = select_obj.get("scope") or branch_prefix.rsplit("-", 1)[-1]
    branch = f"{branch_prefix}-{run_id}-{run_attempt}"
    artifact = f"candidate-{scope_label}-{run_attempt}"
    record = {
        "base": base,
        "head": head,
        "branch": branch,
        "scope": scope_label,
        "commitTitle": commit_title,
        "lockfiles": all_touched,
        "select": select_obj,
    }
    (state / "update.json").write_text(json.dumps(record, indent=2) + "\n")
    subprocess.run(
        ["git", "bundle", "create", str(state / "candidate.bundle"), "HEAD", "^" + base],
        cwd=project_dir,
        check=True,
    )
    write_github_outputs(changed="true", sha=head, artifact=artifact)
    print(f"Prepared update candidate {head} from base {base}.", flush=True)
    return {"changed": True, **record, "artifact": artifact}


def is_local_git_remote(project_dir, remote_name="origin"):
    try:
        remote_url = run(["git", "remote", "get-url", remote_name], cwd=project_dir)
    except subprocess.CalledProcessError:
        return False
    parsed = urlparse(remote_url)
    return parsed.scheme in ("", "file")


def merge(*, project_dir, state):
    project_dir = Path(project_dir).resolve()
    state = Path(state).resolve()
    record = json.loads((state / "update.json").read_text())
    repository = os.environ["GITHUB_REPOSITORY"]
    head = record["head"]
    base = record["base"]
    branch = record["branch"]
    scope_label = record.get("scope", "flake")
    commit_title = record.get("commitTitle", f"chore: update {scope_label} flake inputs")
    lockfiles = ", ".join(f"`{path}`" for path in record.get("lockfiles", ["flake.lock"]))

    bundle = state / "candidate.bundle"
    if run(["git", "rev-parse", "HEAD"], cwd=project_dir) != head and bundle.exists():
        if run(["git", "status", "--porcelain"], cwd=project_dir):
            raise RuntimeError("Working tree must be clean before checking out candidate.bundle")
        subprocess.run(["git", "fetch", str(bundle), "HEAD"], cwd=project_dir, check=True)
        fetched = run(["git", "rev-parse", "FETCH_HEAD"], cwd=project_dir)
        if fetched != head:
            raise RuntimeError(f"candidate.bundle FETCH_HEAD {fetched} != recorded head {head}")
        subprocess.run(["git", "checkout", "--detach", head], cwd=project_dir, check=True)

    if run(["git", "rev-parse", "HEAD"], cwd=project_dir) != head or run(
        ["git", "status", "--porcelain"], cwd=project_dir
    ):
        raise RuntimeError("The verified candidate working tree must remain clean and at record['head']")

    current = run(["gh", "api", f"repos/{repository}/git/ref/heads/master", "--jq", ".object.sha"])
    if current != base:
        print(
            f"Master advanced from {base} to {current}; skipping stale {scope_label} candidate {head}.",
            flush=True,
        )
        if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(summary_path).open("a") as summary:
                summary.write(
                    f"Skipped stale {scope_label} candidate `{head}`: "
                    f"`master` advanced from `{base}` to `{current}`.\n\n"
                )
        write_github_outputs(merged="false", sha=head, remote_master=current)
        return {"merged": False, "reason": "master-advanced", "remoteMaster": current}

    push_cmd = ["git"]
    if not is_local_git_remote(project_dir, "origin"):
        push_cmd += [
            "-c",
            "credential.helper=",
            "-c",
            "credential.helper=!gh auth git-credential",
        ]
    push_cmd += ["push", "origin", f"{head}:refs/heads/{branch}"]
    subprocess.run(push_cmd, cwd=project_dir, check=True)

    body = state / "pull-request.md"
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    run_id = os.environ.get("GITHUB_RUN_ID", "0")
    run_url = f"{server_url}/{repository}/actions/runs/{run_id}"
    body.write_text(
        f"Update locked inputs in {lockfiles}.\n\n"
        f"Validation passed at `{head}` from base `{base}`. [Validation run]({run_url}).\n"
    )
    pr = run(
        [
            "gh",
            "pr",
            "create",
            "--repo",
            repository,
            "--base",
            "master",
            "--head",
            branch,
            "--title",
            commit_title,
            "--body-file",
            str(body),
        ],
        cwd=project_dir,
    )
    try:
        run(
            [
                "gh",
                "api",
                "--method",
                "PATCH",
                f"repos/{repository}/git/refs/heads/master",
                "-f",
                f"sha={head}",
                "-F",
                "force=false",
            ],
            cwd=project_dir,
        )
    except subprocess.CalledProcessError:
        current = run(
            ["gh", "api", f"repos/{repository}/git/ref/heads/master", "--jq", ".object.sha"],
            cwd=project_dir,
        )
        if current != head:
            subprocess.run(
                ["gh", "pr", "close", pr, "--repo", repository, "--delete-branch"],
                cwd=project_dir,
                check=True,
            )
            raise

    deadline = time.monotonic() + 60
    while True:
        status = run(
            ["gh", "pr", "view", pr, "--repo", repository, "--json", "state", "--jq", ".state"],
            cwd=project_dir,
        )
        if status == "MERGED":
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"Master advanced to {head}, but GitHub has not confirmed {pr} as merged; branch retained"
            )
        time.sleep(2)

    run(
        ["gh", "api", "--method", "DELETE", f"repos/{repository}/git/refs/heads/{branch}"],
        cwd=project_dir,
    )
    print(f"Merged {pr} at verified revision {head}.", flush=True)
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a") as summary:
            summary.write(f"Verified update: {pr}\n\nMerged revision: `{head}`.\n\n")
    write_github_outputs(merged="true", sha=head, pr=pr)
    return {"merged": True, "head": head, "pr": pr}
