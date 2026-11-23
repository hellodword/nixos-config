#!/usr/bin/env python3
"""Classify store paths via local Ed25519 signature provenance and publish signed OCI caches."""

import argparse
import base64
import fcntl
from functools import cache
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

try:
    from .build import valid_paths
    from .report import load_manifest, record
except ImportError:
    from build import valid_paths
    from report import load_manifest, record


PARALLEL = 4
LARGE_NAR_BYTES = 512 * 1024 ** 2
BACKGROUND_BATCH = 64
NIX32_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream)
            stream.write("\n")
            stream.flush()
            temporary.chmod(0o644)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def store_root(path):
    return "/".join(str(path).split("/")[:4])


def parse_trusted_public_keys(keys):
    parsed = {}
    for entry in keys or []:
        entry = entry.strip()
        if not entry or ":" not in entry:
            continue
        name, raw_b64 = entry.split(":", 1)
        try:
            parsed[name] = Ed25519PublicKey.from_public_bytes(base64.b64decode(raw_b64))
        except Exception as error:
            raise ValueError(f"Invalid Ed25519 trusted-public-key '{entry}': {error}") from error
    return parsed


def normalize_nar_hash(nar_hash):
    if not isinstance(nar_hash, str) or not nar_hash:
        raise ValueError("missing narHash")
    if nar_hash.startswith("sha256:") and len(nar_hash) == 59:
        return nar_hash
    if nar_hash.startswith("sha256-"):
        raw = base64.b64decode(nar_hash.removeprefix("sha256-"))
        if len(raw) != 32:
            raise ValueError(f"unexpected sha256 byte length {len(raw)}")
        chars = []
        for idx in range(51, -1, -1):
            bit = idx * 5
            byte_idx, bit_offset = bit // 8, bit % 8
            val = (raw[byte_idx] >> bit_offset) | (
                0 if byte_idx >= 31 else (raw[byte_idx + 1] << (8 - bit_offset))
            )
            chars.append(NIX32_ALPHABET[val & 0x1F])
        return "sha256:" + "".join(chars)
    raise ValueError(f"unsupported narHash format: {nar_hash!r}")


def classify_path_info_signature(store_path, info, trusted_keys):
    """Classify path-info entry as ('VALID', signer), ('UNTRUSTED', None), or ('MALFORMED', reason)."""
    if not isinstance(info, dict):
        return ("MALFORMED", "entry is not an object")
    try:
        nar_hash = normalize_nar_hash(info.get("narHash"))
    except Exception as error:
        return ("MALFORMED", str(error))
    nar_size = info.get("narSize")
    if not isinstance(nar_size, int) or nar_size < 0:
        return ("MALFORMED", "missing numeric narSize")

    store_dir = info.get("storeDir") or ("/" + "/".join(store_path.lstrip("/").split("/")[:-1]))
    raw_refs = info.get("references") or []
    full_refs = ",".join(
        sorted(ref if ref.startswith("/") else f"{store_dir}/{ref}" for ref in raw_refs)
    )
    fingerprint = f"1;{store_path};{nar_hash};{nar_size};{full_refs}".encode("ascii")

    for sig in info.get("signatures") or []:
        if not isinstance(sig, str) or ":" not in sig:
            continue
        signer_name, sig_b64 = sig.split(":", 1)
        public_key = trusted_keys.get(signer_name)
        if public_key is None:
            continue
        try:
            public_key.verify(base64.b64decode(sig_b64), fingerprint)
            return ("VALID", signer_name)
        except (InvalidSignature, ValueError):
            continue
    return ("UNTRUSTED", None)


def prepare_inventory(manifest_or_policy):
    roots = manifest_or_policy.get("roots") or []
    cache_cfg = manifest_or_policy.get("cache") or manifest_or_policy
    excluded_paths = cache_cfg.get("excludedPaths") or []
    excluded_drvs = cache_cfg.get("excludedDerivations") or []
    bundles_list = cache_cfg.get("bundles") or []

    graph = (
        json.loads(output(["nix", "derivation", "show", "--recursive", *roots]))["derivations"]
        if roots
        else {}
    )
    outputs = {
        "/nix/store/" + value["path"]
        for node in graph.values()
        for value in node["outputs"].values()
        if value.get("path")
    }
    excluded = {store_root(path) for path in excluded_paths}
    if bundles_list:
        bundles = json.loads(
            output(["nix", "derivation", "show", "--recursive", *bundles_list])
        )["derivations"]
        restricted = {Path(drv).name for drv in excluded_drvs}

        @cache
        def embeds_restricted(drv):
            node = bundles[drv]
            return (
                drv in restricted
                or any("/nix/store/" + path in excluded for path in node["inputs"]["srcs"])
                or any(embeds_restricted(parent) for parent in node["inputs"]["drvs"])
            )

        excluded.update(
            "/nix/store/" + value["path"]
            for drv, node in bundles.items()
            if embeds_restricted(drv)
            for value in node["outputs"].values()
            if value.get("path")
        )
    return {
        "derivations": sorted(graph),
        "outputs": sorted(outputs),
        "excluded": sorted(excluded),
    }


def path_info(paths):
    if not paths:
        return {}
    return json.loads(
        output(
            ["nix", "path-info", "--json", "--json-format", "1", "--stdin"],
            input="".join(path + "\n" for path in sorted(paths)),
        )
    )


class Publisher:
    def __init__(self, state, configuration):
        self.state = Path(state)
        self.configuration = configuration
        self.inventory = configuration["inventory"]
        self.outputs = set(self.inventory["outputs"])
        self.derivations = set(self.inventory["derivations"])
        self.excluded = set(self.inventory["excluded"])

        self.signing_key = os.environ["ORANC_SIGNING_KEY"].strip()
        actual = output(
            ["nix", "key", "convert-secret-to-public"],
            input=self.signing_key,
        )
        if actual != configuration["public_key"]:
            raise RuntimeError("ORANC_SIGNING_KEY does not match the declared cache public key")
        self.public_key = actual
        self.target_key_name = actual.split(":", 1)[0]

        trusted_list = list(configuration.get("trusted_public_keys") or [])
        if self.public_key not in trusted_list:
            trusted_list.append(self.public_key)
        self.trusted_keys = parse_trusted_public_keys(trusted_list)

        self.seen = set()
        self.pending = {}
        self.published = set()
        self.phase = "background"

    def discover(self, paths):
        """Traverse runtime references up to excluded boundaries and classify local Ed25519 signatures."""
        frontier = set(paths) - self.seen
        infos = {}
        while frontier:
            batch = path_info(frontier)
            self.seen.update(batch)
            infos.update(batch)
            frontier = {
                reference
                for path, info in batch.items()
                if path not in self.excluded
                for reference in info["references"]
            } - self.seen
        if not infos:
            return

        excluded = set(infos) & self.excluded
        candidates = {p: i for p, i in infos.items() if p not in excluded}
        record(
            self.state,
            {
                "phase": self.phase,
                "stage": "selection",
                "paths": sorted(candidates),
                "excluded": sorted(excluded),
            },
            "publication-paths.jsonl",
        )

        upstream_hits = set()
        target_hits = set()
        newly_pending = {}

        for store_path, info in sorted(candidates.items()):
            sig_state, signer_name = classify_path_info_signature(
                store_path, info, self.trusted_keys
            )
            if sig_state == "VALID":
                if signer_name == self.target_key_name:
                    target_hits.add(store_path)
                else:
                    upstream_hits.add(store_path)
            else:
                newly_pending[store_path] = info

        self.pending.update(newly_pending)
        record(
            self.state,
            {
                "kind": "publication",
                "phase": self.phase,
                "candidates": len(infos),
                "excluded": len(excluded),
                "upstreamHits": len(upstream_hits),
                "targetHits": len(target_hits),
                "pending": len(newly_pending),
                "narBytes": sum(info["narSize"] for info in newly_pending.values()),
            },
        )
        record(
            self.state,
            {
                "phase": self.phase,
                "stage": "upload",
                "upstreamHits": sorted(upstream_hits),
                "targetHits": sorted(target_hits),
                "pending": {path: info["narSize"] for path, info in newly_pending.items()},
            },
            "publication-paths.jsonl",
        )

    def collect_queue(self):
        queue_dir = self.state / "cache" / "queue"
        if not queue_dir.exists():
            return
        paths = set()
        for event_file in sorted(queue_dir.glob("*.json")):
            event = json.loads(event_file.read_text())
            if Path(event["drv"]).name in self.derivations:
                paths.update(set(event["outputs"]) & self.outputs)
            event_file.unlink()
        self.discover(paths)

    def reconcile(self):
        self.discover(valid_paths(sorted(self.outputs - self.seen)))

    def upload(self, *, drain):
        settings = self.configuration
        command = [
            settings.get("oranc", "oranc"),
            "push",
            "--registry",
            settings["registry"],
            "--repository",
            settings["repository"],
            "--no-closure",
            "--already-signed",
            "--excluded-signing-key-pattern",
            "a^",
            "--zstd-level",
            "3",
            "--max-retry",
            "3",
        ]
        if settings.get("no_ssl"):
            command.append("--no-ssl")
        large_limit = settings.get("large_nar_bytes", LARGE_NAR_BYTES)
        large, regular = [], []
        for path, info in sorted(self.pending.items()):
            (large if info["narSize"] > large_limit else regular).append(path)
        groups = (
            [("large", 1, large), ("regular", PARALLEL, regular)]
            if drain
            else [("regular", 1, regular[:BACKGROUND_BATCH])]
        )
        upload_env = os.environ | {"ORANC_SIGNING_KEY": self.signing_key}
        for name, parallel, group in groups:
            if not group:
                continue
            started = time.monotonic()
            result = subprocess.run(
                [*command, "--parallel", str(parallel)],
                input="".join(path + "\n" for path in group),
                text=True,
                env=upload_env,
            )
            record(
                self.state,
                {
                    "kind": "cache-upload",
                    "phase": self.phase,
                    "group": name,
                    "paths": len(group),
                    "narBytes": sum(self.pending[p]["narSize"] for p in group),
                    "seconds": time.monotonic() - started,
                    "returncode": result.returncode,
                },
            )
            result.check_returncode()
            self.published.update(group)
            for path in group:
                del self.pending[path]
            atomic_json(self.state / "published-paths.json", sorted(self.published))


def enqueue(state):
    atomic_json(
        Path(state) / "cache" / "queue" / (uuid.uuid4().hex + ".json"),
        {"drv": os.environ["DRV_PATH"], "outputs": os.environ["OUT_PATHS"].split()},
    )


def publisher_running(state):
    path = Path(state) / "cache" / "worker.lock"
    if not path.exists():
        return False
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
    return False


def build_publisher_configuration(
    manifest,
    *,
    oranc="oranc",
    no_ssl=False,
    large_nar_bytes=LARGE_NAR_BYTES,
):
    cache_cfg = manifest.get("cache")
    if not cache_cfg:
        raise RuntimeError("Manifest does not declare a cache configuration")
    inventory = prepare_inventory(manifest)
    return {
        "inventory": inventory,
        "public_key": cache_cfg["publicKey"],
        "registry": cache_cfg.get("registry", "ghcr.io"),
        "repository": cache_cfg["repository"],
        "trusted_public_keys": cache_cfg.get("trustedPublicKeys") or [],
        "oranc": oranc,
        "no_ssl": no_ssl,
        "large_nar_bytes": large_nar_bytes,
    }


def start_publisher(
    state,
    inventory,
    *,
    public_key,
    registry,
    repository,
    trusted_public_keys,
    oranc="oranc",
    no_ssl=False,
    large_nar_bytes=LARGE_NAR_BYTES,
):
    state = Path(state).resolve()
    directory = state / "cache"
    directory.mkdir(parents=True, exist_ok=True)
    for sub in ("queue", "requests", "responses"):
        (directory / sub).mkdir(exist_ok=True)
    atomic_json(
        directory / "configuration.json",
        {
            "inventory": inventory,
            "public_key": public_key,
            "registry": registry,
            "repository": repository,
            "trusted_public_keys": list(trusted_public_keys),
            "oranc": oranc,
            "no_ssl": no_ssl,
            "large_nar_bytes": large_nar_bytes,
        },
    )
    hook = directory / "post-build-hook"
    hook.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "from pathlib import Path\n"
        f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
        "from cache import enqueue\n"
        f"enqueue(Path({str(state)!r}))\n"
    )
    hook.chmod(0o755)
    status_file = directory / "status.json"
    status_file.unlink(missing_ok=True)
    (directory / "stop").unlink(missing_ok=True)
    with (state / "publisher.log").open("w") as log:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "serve", "--state", str(state)],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    atomic_json(directory / "pid.json", process.pid)
    while not status_file.exists():
        if process.poll() is not None:
            raise RuntimeError(f"Cache publisher exited during startup; see {state / 'publisher.log'}")
        time.sleep(0.1)
    status = json.loads(status_file.read_text())
    if status["result"] != "running":
        raise RuntimeError(status.get("error", "Cache publisher did not start"))


def serve(state):
    state = Path(state).resolve()
    directory = state / "cache"
    publisher = None

    def terminate(signum, _frame):
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
    state = Path(state).resolve()
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
            (directory / "post-build-hook").unlink(missing_ok=True)
    finally:
        record(
            state,
            {
                "kind": "cache-checkpoint",
                "phase": phase,
                "seconds": time.monotonic() - started,
                "returncode": returncode,
            },
        )


def stop_publisher(state):
    state = Path(state).resolve()
    directory = state / "cache"
    if (directory / "pid.json").exists() and publisher_running(state):
        (directory / "stop").touch()
        pid = json.loads((directory / "pid.json").read_text())
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


def publish_once(state, configuration, *, phase="publish"):
    """Single-process end-of-phase cache verification and publication."""
    state = Path(state).resolve()
    directory = state / "cache"
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    returncode = 1
    try:
        publisher = Publisher(state, configuration)
        publisher.phase = phase
        publisher.reconcile()
        publisher.upload(drain=True)
        atomic_json(directory / "status.json", {"result": "success"})
        returncode = 0
        return sorted(publisher.published)
    except BaseException as error:
        message = f"{type(error).__name__}: {error}"
        atomic_json(directory / "status.json", {"result": "failure", "error": message})
        record(state, {"kind": "cache-error", "phase": phase, "error": message})
        raise
    finally:
        record(
            state,
            {
                "kind": "cache-checkpoint",
                "phase": phase,
                "seconds": time.monotonic() - started,
                "returncode": returncode,
            },
        )


def resolve_oranc_executable(state):
    oranc_file = Path(state) / "oranc"
    if oranc_file.exists():
        return oranc_file.read_text().strip()
    return "oranc"


def run_cache_command(*, operation, state, project_dir=None, phase="publication", finish=False, no_ssl=False):
    state = Path(state).resolve()
    if operation == "start":
        manifest = load_manifest(state)
        cfg = build_publisher_configuration(
            manifest,
            oranc=resolve_oranc_executable(state),
            no_ssl=no_ssl,
        )
        start_publisher(
            state,
            cfg["inventory"],
            public_key=cfg["public_key"],
            registry=cfg["registry"],
            repository=cfg["repository"],
            trusted_public_keys=cfg["trusted_public_keys"],
            oranc=cfg["oranc"],
            no_ssl=cfg["no_ssl"],
            large_nar_bytes=cfg["large_nar_bytes"],
        )
    elif operation == "serve":
        serve(state)
    elif operation == "checkpoint":
        checkpoint(state, phase, finish=finish)
    elif operation == "stop":
        stop_publisher(state)
    elif operation == "publish":
        manifest = load_manifest(state)
        cfg = build_publisher_configuration(
            manifest,
            oranc=resolve_oranc_executable(state),
            no_ssl=no_ssl,
        )
        publish_once(state, cfg, phase=phase)
    else:
        raise ValueError(f"Unsupported cache operation: {operation}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["start", "serve", "checkpoint", "stop", "publish"])
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--project-dir", type=Path, default=Path("."))
    parser.add_argument("--phase", default="publication")
    parser.add_argument("--finish", action="store_true")
    parser.add_argument("--no-ssl", action="store_true")
    args = parser.parse_args(argv)
    run_cache_command(
        operation=args.operation,
        state=args.state,
        project_dir=args.project_dir,
        phase=args.phase,
        finish=args.finish,
        no_ssl=args.no_ssl,
    )


if __name__ == "__main__":
    main()
