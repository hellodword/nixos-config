#!/usr/bin/env python3
"""Publish completed Nix outputs while CI builds, then drain at phase boundaries."""

import argparse
import fcntl
from functools import cache
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

from build import valid_paths
from report import record


ROOT = Path(__file__).resolve().parents[2]
PARALLEL = 4
LARGE_NAR_BYTES = 512 * 1024 ** 2
BACKGROUND_BATCH = 64


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream)
            stream.write("\n")
            stream.flush()
            # A daemon's hook may run as root while the publisher is its caller.
            temporary.chmod(0o644)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def load_cache_settings():
    caches = json.loads(output([
        "nix", "eval", "--json", "--file", str(ROOT / "nix/cache-config.nix"),
        "--apply", "c: { inherit (c) publicSettings ci; }",
    ]))
    defaults = json.loads(output(["nix", "config", "show", "--json"]))
    return {
        "public_settings": {
            key: list(dict.fromkeys(defaults[key]["defaultValue"] + caches["publicSettings"][key]))
            for key in ("substituters", "trusted-public-keys")
        },
        "project_cache": caches["ci"]["uri"],
    }


def store_root(path):
    return "/".join(path.split("/")[:4])


def prepare_inventory(policy):
    graph = json.loads(output(["nix", "derivation", "show", "--recursive", *policy["roots"]]))["derivations"]
    outputs = {"/nix/store/" + value["path"] for node in graph.values()
               for value in node["outputs"].values() if value.get("path")}
    excluded = {store_root(path) for path in policy["excludedPaths"]}
    if policy["bundles"]:
        bundles = json.loads(output(["nix", "derivation", "show", "--recursive", *policy["bundles"]]))["derivations"]
        restricted = {Path(drv).name for drv in policy["excludedDerivations"]}

        @cache
        def embeds_restricted(drv):
            node = bundles[drv]
            return (drv in restricted
                    or any("/nix/store/" + path in excluded for path in node["inputs"]["srcs"])
                    or any(embeds_restricted(parent) for parent in node["inputs"]["drvs"]))

        # Bundles copy payloads; their restricted intermediates are private too.
        # Ordinary system reference graphs remain reusable.
        excluded.update("/nix/store/" + value["path"] for drv, node in bundles.items() if embeds_restricted(drv)
                        for value in node["outputs"].values() if value.get("path"))
    return {"derivations": sorted(graph), "outputs": sorted(outputs), "excluded": sorted(excluded)}


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


class Publisher:
    def __init__(self, state, configuration):
        self.state = state
        self.configuration = configuration
        self.inventory = configuration["inventory"]
        self.outputs = set(self.inventory["outputs"])
        self.derivations = set(self.inventory["derivations"])
        self.excluded = set(self.inventory["excluded"])
        self.public_names = {key.split(":", 1)[0] for key in configuration["public_settings"]["trusted-public-keys"]}
        actual = output(["nix", "key", "convert-secret-to-public"], input=os.environ["ORANC_SIGNING_KEY"])
        if actual != configuration["public_key"]:
            raise RuntimeError("NIX_CACHE_SIGNING_KEY does not match the declared cache public key")
        self.project_name = actual.split(":", 1)[0]
        self.seen, self.pending, self.published = set(), {}, set()
        self.phase = "background"

    def discover(self, paths):
        """Read each runtime reference once, including evaluation-created files."""
        frontier, infos = set(paths) - self.seen, {}
        while frontier:
            batch = path_info(frontier)
            self.seen.update(batch)
            infos.update(batch)
            frontier = {reference for info in batch.values() for reference in info["references"]} - self.seen
        if not infos:
            return
        excluded = set(infos) & self.excluded
        record(self.state, {"phase": self.phase, "stage": "selection", "paths": sorted(set(infos) - excluded),
                            "excluded": sorted(excluded)}, "publication-paths.jsonl")
        pending, public, project = cached_paths({p: i for p, i in infos.items() if p not in excluded},
                                               self.public_names, self.project_name)
        settings = self.configuration
        for uri in dict.fromkeys([*settings["public_settings"]["substituters"], settings["project_cache"]]):
            if not pending:
                break
            started = time.monotonic()
            result = subprocess.run([
                "nix", "store", "copy-sigs", "--substituter", uri, "--stdin",
                "--option", "http-connections", str(PARALLEL),
                "--option", "narinfo-cache-negative-ttl", "0",
            ], input="".join(path + "\n" for path in sorted(pending)), text=True, capture_output=True)
            event = {"kind": "cache-query", "phase": self.phase, "cache": uri,
                     "seconds": time.monotonic() - started, "returncode": result.returncode}
            if result.returncode:
                event["error"] = result.stderr.strip()
            record(self.state, event)
            print(json.dumps(event), flush=True)
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
            # Failed queries can still import signatures for some paths.
            pending, found_public, found_project = cached_paths(path_info(pending), self.public_names, self.project_name)
            public.update(found_public)
            project.update(found_project)
        self.pending.update(pending)
        record(self.state, {"kind": "publication", "phase": self.phase,
                            "candidates": len(infos), "excluded": len(excluded),
                            "public": len(public), "project": len(project), "pending": len(pending),
                            "narBytes": sum(info["narSize"] for info in pending.values())})
        record(self.state, {"phase": self.phase, "stage": "upload", "public": sorted(public), "project": sorted(project),
                            "pending": {path: info["narSize"] for path, info in pending.items()}}, "publication-paths.jsonl")

    def collect_queue(self):
        paths = set()
        for event_file in sorted((self.state / "cache" / "queue").glob("*.json")):
            event = json.loads(event_file.read_text())
            if Path(event["drv"]).name in self.derivations:
                paths.update(set(event["outputs"]) & self.outputs)
            event_file.unlink()
        self.discover(paths)

    def reconcile(self):
        # Hooks omit substitutions and outputs present before the publisher.
        self.discover(valid_paths(sorted(self.outputs - self.seen)))

    def upload(self, *, drain):
        settings = self.configuration
        pattern = "^(?:" + "|".join(re.escape(name) for name in sorted(self.public_names)) + ")$"
        command = [settings["oranc"], "push", "--registry", settings["registry"], "--repository", settings["repository"],
                   "--no-closure", "--excluded-signing-key-pattern", pattern, "--zstd-level", "3", "--max-retry", "3"]
        if settings["no_ssl"]:
            command.append("--no-ssl")
        large, regular = [], []
        for path, info in sorted(self.pending.items()):
            (large if info["narSize"] > settings["large_nar_bytes"] else regular).append(path)
        groups = [("large", 1, large), ("regular", PARALLEL, regular)] if drain else [
            ("regular", 1, regular[:BACKGROUND_BATCH])]
        for name, parallel, group in groups:
            if not group:
                continue
            started = time.monotonic()
            result = subprocess.run([*command, "--parallel", str(parallel)],
                                    input="".join(path + "\n" for path in group), text=True)
            record(self.state, {"kind": "cache-upload", "phase": self.phase, "group": name, "paths": len(group),
                                "narBytes": sum(self.pending[p]["narSize"] for p in group),
                                "seconds": time.monotonic() - started, "returncode": result.returncode})
            result.check_returncode()
            self.published.update(group)
            for path in group:
                del self.pending[path]
            # oranc signs remote narinfo without adding a local Nix signature.
            atomic_json(self.state / "published-paths.json", sorted(self.published))


def enqueue(state):
    atomic_json(state / "cache" / "queue" / (uuid.uuid4().hex + ".json"),
                {"drv": os.environ["DRV_PATH"], "outputs": os.environ["OUT_PATHS"].split()})


def publisher_running(state):
    path = state / "cache" / "worker.lock"
    if not path.exists():
        return False
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
    return False


def start_publisher(state, inventory, *, public_key, registry, repository, public_settings, project_cache,
                    oranc="oranc", no_ssl=False, large_nar_bytes=LARGE_NAR_BYTES):
    state = state.resolve()
    directory = state / "cache"
    directory.mkdir(parents=True)
    (directory / "queue").mkdir()
    (directory / "requests").mkdir()
    (directory / "responses").mkdir()
    atomic_json(directory / "configuration.json", {
        "inventory": inventory, "public_key": public_key, "registry": registry, "repository": repository,
        "public_settings": public_settings, "project_cache": project_cache, "oranc": oranc,
        "no_ssl": no_ssl, "large_nar_bytes": large_nar_bytes,
    })
    # Use the prepared interpreter and absolute paths, including for daemon hooks.
    hook = directory / "post-build-hook"
    hook.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\n"
                    f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
                    f"from cache import enqueue\nenqueue(Path({str(state)!r}))\n")
    hook.chmod(0o755)
    with (state / "publisher.log").open("w") as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "serve", "--state", str(state)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    atomic_json(directory / "pid.json", process.pid)
    while not (directory / "status.json").exists():
        if process.poll() is not None:
            raise RuntimeError(f"Cache publisher exited during startup; see {state / 'publisher.log'}")
        time.sleep(0.1)
    status = json.loads((directory / "status.json").read_text())
    if status["result"] != "running":
        raise RuntimeError(status.get("error", "Cache publisher did not start"))


def serve(state):
    directory = state / "cache"
    publisher = None

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    with (directory / "worker.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            publisher = Publisher(state, json.loads((directory / "configuration.json").read_text()))
            atomic_json(directory / "status.json", {"result": "running"})
            publisher.reconcile()
            while True:
                requests = sorted((directory / "requests").glob("*.json"))
                if requests:
                    request_file = requests[0]
                    request = json.loads(request_file.read_text())
                    publisher.phase = request["phase"]
                    publisher.collect_queue()
                    publisher.reconcile()
                    publisher.upload(drain=True)
                    atomic_json(directory / "responses" / request_file.name, {"result": "success"})
                    request_file.unlink()
                    if request["finish"]:
                        atomic_json(directory / "status.json", {"result": "success"})
                        return
                    publisher.phase = "background"
                else:
                    publisher.collect_queue()
                    publisher.upload(drain=False)
                    time.sleep(1)
        except BaseException as error:
            if isinstance(error, SystemExit) and (directory / "stop").exists():
                atomic_json(directory / "status.json", {"result": "stopped"})
                return
            phase = publisher.phase if publisher else "publisher-start"
            message = f"{type(error).__name__}: {error}"
            atomic_json(directory / "status.json", {"result": "failure", "error": message})
            record(state, {"kind": "cache-error", "phase": phase, "error": message})
            traceback.print_exc()
            raise


def checkpoint(state, phase, *, finish=False):
    directory = state / "cache"
    request_id = uuid.uuid4().hex + ".json"
    started = time.monotonic()
    returncode = 1
    try:
        atomic_json(directory / "requests" / request_id, {"phase": phase, "finish": finish})
        response = directory / "responses" / request_id
        while not response.exists():
            status = json.loads((directory / "status.json").read_text())
            if status["result"] == "failure":
                raise RuntimeError(f"Cache publisher failed: {status['error']}; see publisher.log")
            if not publisher_running(state) and not response.exists():
                raise RuntimeError("Cache publisher exited before completing publication; see publisher.log")
            time.sleep(0.2)
        returncode = 0
        if finish:
            (directory / "post-build-hook").unlink()
    finally:
        record(state, {"kind": "cache-checkpoint", "phase": phase,
                       "seconds": time.monotonic() - started, "returncode": returncode})


def stop_publisher(state):
    directory = state / "cache"
    if (directory / "pid.json").exists() and publisher_running(state):
        (directory / "stop").touch()
        pid = json.loads((directory / "pid.json").read_text())
        # The worker owns this process group, including active Nix/oranc clients.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pid, sig)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + 5
            while publisher_running(state) and time.monotonic() < deadline:
                time.sleep(0.1)
            if not publisher_running(state):
                break
    (directory / "post-build-hook").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["start", "serve", "checkpoint", "stop"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--phase", default="publication", help="publication checkpoint name")
    parser.add_argument("--finish", action="store_true", help="exit the publisher after this checkpoint")
    args = parser.parse_args()
    state = args.state.resolve()
    if args.operation == "start":
        policy = json.loads((state / "policy.json").read_text())
        identity = json.loads((ROOT / "nix/cache-identity.json").read_text())
        start_publisher(state, prepare_inventory(policy), public_key=identity["publicKey"],
                        registry="ghcr.io", repository=identity["repository"], **load_cache_settings(),
                        oranc=(state / "oranc").read_text().strip())
    elif args.operation == "serve":
        serve(state)
    elif args.operation == "checkpoint":
        checkpoint(state, args.phase, finish=args.finish)
    else:
        stop_publisher(state)


if __name__ == "__main__":
    main()
