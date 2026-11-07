#!/usr/bin/env python3
"""Select realized, redistributable build paths and publish with oranc."""

import argparse
from functools import cache
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def store_root(path):
    return "/".join(path.split("/")[:4])


def select_paths(policy):
    candidates = set(output([
        "nix-store", "--query", "--requisites", "--include-outputs", *policy["roots"],
    ]).splitlines())
    candidates = {path for path in candidates if not path.endswith(".drv")}
    excluded = {store_root(path) for path in policy["excludedPaths"]}
    if policy["bundles"]:
        # Nix 2.34's derivation JSON uses store basenames inside `derivations`.
        graph = json.loads(output(["nix", "derivation", "show", "--recursive", *policy["bundles"]]))["derivations"]
        restricted = {Path(drv).name for drv in policy["excludedDerivations"]}

        @cache
        def embeds_restricted(drv):
            node = graph[drv]
            return (drv in restricted
                    or any("/nix/store/" + path in excluded for path in node["inputs"]["srcs"])
                    or any(embeds_restricted(parent) for parent in node["inputs"]["drvs"]))

        # Bundles copy payloads; all intermediates on their restricted input
        # paths are private too. Ordinary system reference graphs stay reusable.
        bundled = {"/nix/store/" + value["path"] for drv, node in graph.items() if embeds_restricted(drv)
                   for value in node["outputs"].values() if value.get("path")}
        excluded.update(bundled)
    return sorted(candidates - excluded), sorted(candidates & excluded)


def publish(paths, registry, repository, *, oranc="oranc", no_ssl=False, immutable=False):
    command = [oranc, "push", "--registry", registry, "--repository", repository,
               "--no-closure", "--parallel", "1", "--zstd-level", "3", "--max-retry", "3"]
    if no_ssl:
        command.append("--no-ssl")
    if immutable:
        command.append("--allow-immutable-db")
    subprocess.run([*command, "initialize", "--priority", "41"], check=True)
    subprocess.run(command, input="".join(path + "\n" for path in paths), text=True, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "build", "select", "publish"])
    parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    policy = json.loads((args.state / "policy.json").read_text())
    if args.operation in ("prepare", "build"):
        roots = policy["prepare" if args.operation == "prepare" else "roots"]
        # Evaluation has exited before the VM builder starts, releasing its heap.
        subprocess.run(["nix", "build", "--no-link", "--print-build-logs",
                        *[drv + "^*" for drv in roots]], check=True)
    elif args.operation == "select":
        paths, excluded = select_paths(policy)
        (args.state / "publish-paths.json").write_text(json.dumps(paths) + "\n")
        (args.state / "excluded-paths.json").write_text(json.dumps(excluded, indent=2) + "\n")
        print(json.dumps({"publishablePaths": len(paths), "excludedPaths": excluded}))
    else:
        identity = json.loads((ROOT / "nix/cache-identity.json").read_text())
        # Compare the secret to the tracked identity before any registry write.
        public = output(["nix", "key", "convert-secret-to-public"], input=os.environ["ORANC_SIGNING_KEY"])
        if public != identity["publicKey"]:
            raise RuntimeError("NIX_CACHE_SIGNING_KEY does not match nix/cache-identity.json")
        paths = json.loads((args.state / "publish-paths.json").read_text())
        publish(paths, "ghcr.io", identity["repository"], oranc=(args.state / "oranc").read_text().strip())


if __name__ == "__main__":
    main()
