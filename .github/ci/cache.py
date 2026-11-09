#!/usr/bin/env python3
"""Select realized, redistributable build paths and publish with oranc."""

import argparse
from functools import cache
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from build import valid_paths
from report import record


ROOT = Path(__file__).resolve().parents[2]
PARALLEL = 4
LARGE_NAR_BYTES = 512 * 1024 ** 2


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def store_root(path):
    return "/".join(path.split("/")[:4])


def select_paths(policy):
    graph = json.loads(output(["nix", "derivation", "show", "--recursive", *policy["roots"]]))["derivations"]
    outputs = {"/nix/store/" + value["path"] for node in graph.values()
               for value in node["outputs"].values() if value.get("path")}
    realized = valid_paths(sorted(outputs))
    # Runtime references also include files created directly by Nix evaluation.
    candidates = set(output(["nix-store", "--query", "--requisites", *sorted(realized)]).splitlines()) if realized else set()
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


def path_info(paths):
    if not paths:
        return {}
    return json.loads(output(["nix", "path-info", "--json", "--json-format", "1", "--stdin"],
                             input="".join(path + "\n" for path in sorted(paths))))


def cached_paths(infos, public_names, project_name):
    public, project, pending = set(), set(), {}
    for path, info in infos.items():
        names = {signature.split(":", 1)[0] for signature in info.get("signatures", [])}
        if names & public_names:
            public.add(path)
        elif project_name in names:
            project.add(path)
        else:
            pending[path] = info
    return pending, public, project


def publish(paths, registry, repository, *, state, public_settings, project_cache,
            phase="publication", excluded_paths=(), oranc="oranc", no_ssl=False, immutable=False):
    public_names = {key.split(":", 1)[0] for key in public_settings["trusted-public-keys"]}
    public_key = output(["nix", "key", "convert-secret-to-public"], input=os.environ["ORANC_SIGNING_KEY"])
    project_name = public_key.split(":", 1)[0]
    pattern = "^(?:" + "|".join(re.escape(name) for name in sorted(public_names)) + ")$"
    # oranc signs the uploaded narinfo without adding signatures to the local
    # Nix database. Remember completed batches across this run's checkpoints.
    receipt = state / "published-paths.json"
    previous = set(json.loads(receipt.read_text())) if receipt.exists() else set()
    record(state, {"phase": phase, "stage": "selection", "paths": sorted(paths),
                   "excluded": sorted(excluded_paths)}, "publication-paths.jsonl")
    pending, public, project = cached_paths(path_info(set(paths) - previous), public_names, project_name)
    project.update(set(paths) & previous)
    for uri in dict.fromkeys([*public_settings["substituters"], project_cache]):
        if not pending:
            break
        started = time.monotonic()
        result = subprocess.run([
            "nix", "store", "copy-sigs", "--substituter", uri, "--stdin",
            "--option", "http-connections", str(PARALLEL),
            "--option", "narinfo-cache-negative-ttl", "0",
        ], input="".join(path + "\n" for path in sorted(pending)), text=True, capture_output=True)
        event = {"kind": "cache-query", "phase": phase, "cache": uri,
                 "seconds": time.monotonic() - started, "returncode": result.returncode}
        if result.returncode:
            event["error"] = result.stderr.strip()
        record(state, event)
        print(json.dumps(event), flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        # A failed query can still have imported signatures for some paths.
        pending, found_public, found_project = cached_paths(path_info(pending), public_names, project_name)
        public.update(found_public)
        project.update(found_project)

    record(state, {"kind": "publication", "phase": phase,
                   "candidates": len(paths) + len(excluded_paths), "excluded": len(excluded_paths),
                   "public": len(public), "project": len(project), "pending": len(pending),
                   "narBytes": sum(info["narSize"] for info in pending.values())})
    record(state, {"phase": phase, "stage": "upload", "public": sorted(public), "project": sorted(project),
                   "pending": {path: pending[path]["narSize"] for path in sorted(pending)}}, "publication-paths.jsonl")
    command = [oranc, "push", "--registry", registry, "--repository", repository,
               "--no-closure", "--excluded-signing-key-pattern", pattern, "--zstd-level", "3", "--max-retry", "3"]
    if no_ssl:
        command.append("--no-ssl")
    if immutable:
        command.append("--allow-immutable-db")
    groups = [("large", 1, [path for path, info in pending.items() if info["narSize"] > LARGE_NAR_BYTES]),
              ("regular", PARALLEL, [path for path, info in pending.items() if info["narSize"] <= LARGE_NAR_BYTES])]
    for name, parallel, group in groups:
        if not group:
            continue
        started = time.monotonic()
        result = subprocess.run([*command, "--parallel", str(parallel)],
                                input="".join(path + "\n" for path in sorted(group)), text=True)
        record(state, {"kind": "cache-upload", "phase": phase, "group": name, "paths": len(group),
                       "seconds": time.monotonic() - started, "returncode": result.returncode})
        result.check_returncode()
        previous.update(group)
        temporary = receipt.with_suffix(".tmp")
        temporary.write_text(json.dumps(sorted(previous)) + "\n")
        temporary.replace(receipt)
    return sorted(pending)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["select", "publish"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--phase", default="publication", help="publication checkpoint name in diagnostics")
    args = parser.parse_args()
    policy = json.loads((args.state / "policy.json").read_text())
    if args.operation == "select":
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
        caches = json.loads(output(["nix", "eval", "--json", "--file", str(ROOT / "nix/cache-config.nix")]))
        defaults = json.loads(output(["nix", "config", "show", "--json"]))
        public_settings = {key: list(dict.fromkeys(defaults[key]["defaultValue"] + caches["publicSettings"][key]))
                           for key in ("substituters", "trusted-public-keys")}
        paths = json.loads((args.state / "publish-paths.json").read_text())
        excluded = json.loads((args.state / "excluded-paths.json").read_text())
        published = publish(paths, "ghcr.io", identity["repository"], state=args.state,
                            public_settings=public_settings, project_cache=caches["ci"]["uri"],
                            phase=args.phase, excluded_paths=excluded,
                            oranc=(args.state / "oranc").read_text().strip())
        print(json.dumps({"newPaths": len(published), "selectedPaths": len(paths)}))


if __name__ == "__main__":
    main()
