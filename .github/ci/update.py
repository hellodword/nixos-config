#!/usr/bin/env python3
"""Prepare a local update candidate, then publish its verified revision through GitHub."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time


TITLE = "chore: update tracked flake inputs"


def run(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def prepare(state):
    state.mkdir(parents=True, exist_ok=True)
    changed = run(["git", "diff", "--name-only", "HEAD"]).splitlines()
    if changed != ["flake.lock"]:
        raise RuntimeError(f"Expected only the checked lockfile to change, got {changed}")
    base = run(["git", "rev-parse", "HEAD"])
    subprocess.run(["git", "add", "--", "flake.lock"], check=True)
    subprocess.run(["git", "-c", "user.name=github-actions[bot]",
                    "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                    "-c", "commit.gpgsign=false", "commit", "-m", TITLE], check=True)
    head = run(["git", "rev-parse", "HEAD"])
    record = {"base": base, "head": head,
              "branch": f"automation/flake-update-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}"}
    (state / "update.json").write_text(json.dumps(record) + "\n")
    subprocess.run(["git", "bundle", "create", str(state / "candidate.bundle"), "HEAD", "^" + base], check=True)
    print(f"Local candidate {head}; validation precedes publication.")


def merge(state):
    record = json.loads((state / "update.json").read_text())
    repository = os.environ["GITHUB_REPOSITORY"]
    head, branch = record["head"], record["branch"]
    if run(["git", "rev-parse", "HEAD"]) != head or run(["git", "status", "--porcelain"]):
        raise RuntimeError("The verified candidate must remain clean and unchanged")
    subprocess.run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
                    "push", "origin", f"{head}:refs/heads/{branch}"], check=True)
    body = state / "pull-request.md"
    run_url = f"{os.environ['GITHUB_SERVER_URL']}/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    body.write_text(
        "Update the tracked upstream inputs in flake.lock. Installation inputs, oranc and the optional remote VM client keep their existing revisions.\n\n"
        f"Validation: every selected host passed its system build, domain checks, OCI cache integration "
        f"and four VM suites at `{head}`. Signed redistributable paths were published.\n\n"
        f"Base: `{record['base']}`. [Validation run]({run_url}).\n"
    )
    pr = run(["gh", "pr", "create", "--repo", repository, "--base", "master", "--head", branch,
              "--title", TITLE, "--body-file", str(body)])
    # A concurrent master update cannot be overwritten by this non-forced FF.
    try:
        run(["gh", "api", "--method", "PATCH", f"repos/{repository}/git/refs/heads/master",
             "-f", f"sha={head}", "-F", "force=false"])
    except subprocess.CalledProcessError:
        # A failed HTTP response can follow a successful write: retain the PR
        # unless the remote head proves that this candidate was not merged.
        current = run(["gh", "api", f"repos/{repository}/git/ref/heads/master", "--jq", ".object.sha"])
        if current != head:
            subprocess.run(["gh", "pr", "close", pr, "--repo", repository, "--delete-branch"], check=True)
            raise
    deadline = time.monotonic() + 60
    while True:
        status = run(["gh", "pr", "view", pr, "--repo", repository, "--json", "state", "--jq", ".state"])
        if status == "MERGED":
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Master advanced to {head}, but GitHub has not confirmed {pr} as merged; branch retained")
        time.sleep(2)
    run(["gh", "api", "--method", "DELETE", f"repos/{repository}/git/refs/heads/{branch}"])
    print(f"Merged {pr} at the verified revision {head}")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(f"Verified update: {pr}\n\nMerged revision: `{head}`.\n\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "merge"])
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    {"prepare": prepare, "merge": merge}[args.operation](args.state)


if __name__ == "__main__":
    main()
