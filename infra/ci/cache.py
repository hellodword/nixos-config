#!/usr/bin/env python3
"""Verify remote .narinfo availability with Ed25519 signatures and publish signed OCI caches."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
from functools import cache
import json
import netrc as netrc_lib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
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
QUERY_CONCURRENCY = 8
LARGE_NAR_BYTES = 512 * 1024 ** 2
BACKGROUND_BATCH = 64
RETRY_DELAYS = (0.5, 1.5, 3.0)
RETRYABLE_HTTP_CODES = {408, 429, 500, 502, 503, 504}


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


def classify_narinfo_signature(narinfo_text, expected_store_path, trusted_keys):
    """Classify .narinfo text as ('VALID', signer), ('UNTRUSTED', None), or ('MALFORMED', reason)."""
    fields = {}
    signatures = []
    for raw_line in narinfo_text.splitlines():
        line = raw_line.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if key == "Sig":
            signatures.append(value)
        else:
            fields[key] = value

    store_path = fields.get("StorePath")
    nar_hash = fields.get("NarHash")
    nar_size = fields.get("NarSize")
    if store_path != expected_store_path:
        return ("MALFORMED", f"StorePath={store_path!r} != expected {expected_store_path!r}")
    if not nar_hash or not nar_size or not nar_size.isdigit():
        return ("MALFORMED", "missing NarHash or numeric NarSize")

    store_dir = "/" + "/".join(expected_store_path.lstrip("/").split("/")[:-1])
    refs = fields.get("References", "").split()
    full_refs = ",".join(sorted(f"{store_dir}/{ref}" for ref in refs))
    fingerprint = f"1;{store_path};{nar_hash};{nar_size};{full_refs}".encode("ascii")

    for sig in signatures:
        if ":" not in sig:
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


def verify_narinfo_signature(narinfo_text, expected_store_path, trusted_keys):
    """Parse .narinfo text and return the verified trusted signer name, or None."""
    state, detail = classify_narinfo_signature(narinfo_text, expected_store_path, trusted_keys)
    return detail if state == "VALID" else None


def discover_netrc_files():
    candidates = []
    if env_netrc := os.environ.get("NIX_CI_NETRC"):
        candidates.append(Path(env_netrc))
    ci_netrc = Path("/ci/oranc.netrc")
    if ci_netrc.exists():
        candidates.append(ci_netrc)
    nix_config = os.environ.get("NIX_CONFIG", "")
    for line in nix_config.splitlines():
        stripped = line.strip()
        if stripped.startswith("netrc-file"):
            _, rhs = stripped.split("=", 1)
            if rhs.strip():
                candidates.append(Path(rhs.strip()))
    for conf_file in os.environ.get("NIX_USER_CONF_FILES", "").split(":"):
        if not conf_file:
            continue
        conf_path = Path(conf_file)
        if conf_path.exists():
            for line in conf_path.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("netrc-file"):
                    _, rhs = stripped.split("=", 1)
                    if rhs.strip():
                        candidates.append(Path(rhs.strip()))
    unique = []
    seen = set()
    for path in candidates:
        resolved = str(path)
        if resolved not in seen and path.exists():
            seen.add(resolved)
            unique.append(path)
    return unique


def basic_auth_header_for_host(hostname, netrc_files):
    if not hostname:
        return None
    for path in netrc_files:
        try:
            parsed = netrc_lib.netrc(str(path))
            auth = parsed.authenticators(hostname)
            if auth:
                login, account, password = auth
                user = login or account or ""
                secret = password or ""
                token = base64.b64encode(f"{user}:{secret}".encode("utf-8")).decode("ascii")
                return f"Basic {token}"
        except Exception:
            continue
    return None


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

        actual = output(
            ["nix", "key", "convert-secret-to-public"],
            input=os.environ["ORANC_SIGNING_KEY"],
        )
        if actual != configuration["public_key"]:
            raise RuntimeError("ORANC_SIGNING_KEY does not match the declared cache public key")
        self.public_key = actual
        self.target_key_name = actual.split(":", 1)[0]

        trusted_list = list(configuration.get("trusted_public_keys") or [])
        if self.public_key not in trusted_list:
            trusted_list.append(self.public_key)
        self.trusted_keys = parse_trusted_public_keys(trusted_list)

        target_uri = configuration.get("target_uri")
        raw_substituters = list(configuration.get("read_substituters") or [])
        ordered_uris = []
        if target_uri:
            ordered_uris.append(target_uri.rstrip("/"))
        for uri in raw_substituters:
            cleaned = uri.rstrip("/")
            if cleaned and cleaned not in ordered_uris:
                ordered_uris.append(cleaned)
        self.target_uri = target_uri.rstrip("/") if target_uri else None
        self.substituter_uris = ordered_uris
        self.retry_delays = tuple(configuration.get("retry_delays", RETRY_DELAYS))
        self.query_concurrency = int(configuration.get("query_concurrency", QUERY_CONCURRENCY))
        self.request_timeout = float(configuration.get("request_timeout", 15.0))
        self.netrc_files = discover_netrc_files()

        self.query_cache = {}
        self.query_lock = threading.Lock()
        self.seen = set()
        self.pending = {}
        self.published = set()
        self.query_failures = {}
        self.phase = "background"

    def _fetch_narinfo_once(self, uri, store_hash):
        parsed = urlparse(uri)
        if parsed.scheme == "file":
            narinfo_file = Path(parsed.path) / f"{store_hash}.narinfo"
            if not narinfo_file.exists():
                return 404, None
            return 200, narinfo_file.read_text(encoding="utf-8", errors="replace")

        narinfo_url = f"{uri}/{store_hash}.narinfo"
        headers = {"Accept": "text/x-nix-narinfo, text/plain;q=0.9, */*;q=0.1"}
        auth_header = basic_auth_header_for_host(parsed.hostname, self.netrc_files)
        if auth_header:
            headers["Authorization"] = auth_header
        request = Request(narinfo_url, headers=headers, method="GET")
        try:
            with urlopen(request, timeout=self.request_timeout) as response:
                return response.status, response.read().decode("utf-8", errors="replace")
        except HTTPError as http_err:
            if http_err.code == 404:
                return 404, None
            raise RuntimeError(f"HTTP {http_err.code}") from http_err
        except (URLError, TimeoutError, OSError) as net_err:
            raise RuntimeError(f"network error: {net_err}") from net_err

    def _probe_substituter(self, uri, store_path, *, bypass_cache=False, retry_on_miss=False):
        store_hash = Path(store_path).name.split("-", 1)[0]
        cache_key = (uri, store_hash)
        if not bypass_cache:
            with self.query_lock:
                if cache_key in self.query_cache:
                    return self.query_cache[cache_key]

        is_target = bool(self.target_uri and uri == self.target_uri)
        last_error = None
        for attempt in range(len(self.retry_delays) + 1):
            try:
                status, body = self._fetch_narinfo_once(uri, store_hash)
                if status == 404:
                    if retry_on_miss and attempt < len(self.retry_delays):
                        last_error = "HTTP 404 after upload"
                    else:
                        outcome = ("MISS", None)
                        with self.query_lock:
                            self.query_cache[cache_key] = outcome
                        return outcome
                elif status == 200 and body is not None:
                    sig_state, sig_detail = classify_narinfo_signature(
                        body, store_path, self.trusted_keys
                    )
                    if sig_state == "VALID":
                        outcome = ("HIT", sig_detail)
                        with self.query_lock:
                            self.query_cache[cache_key] = outcome
                        return outcome
                    if sig_state == "UNTRUSTED" and is_target:
                        if retry_on_miss and attempt < len(self.retry_delays):
                            last_error = "target narinfo lacks trusted signature after upload"
                        else:
                            outcome = ("MISS", None)
                            with self.query_lock:
                                self.query_cache[cache_key] = outcome
                            return outcome
                    elif sig_state == "UNTRUSTED":
                        last_error = "HTTP 200 narinfo lacks trusted signature"
                    else:
                        last_error = f"HTTP 200 malformed narinfo ({sig_detail})"
                else:
                    last_error = f"unexpected HTTP status {status}"
            except Exception as error:
                last_error = str(error)

            if attempt < len(self.retry_delays):
                time.sleep(self.retry_delays[attempt])

        return ("ERROR", last_error or "unknown query failure")

    def _classify_path(self, store_path):
        errors = []
        for uri in self.substituter_uris:
            state, detail = self._probe_substituter(uri, store_path)
            if state == "HIT":
                if self.target_uri and uri == self.target_uri:
                    return ("TARGET_HIT", uri, detail)
                return ("UPSTREAM_HIT", uri, detail)
            if state == "ERROR":
                errors.append((uri, detail))
        if errors:
            return ("QUERY_ERROR", errors[0][0], errors)
        return ("MISS", None, None)

    def discover(self, paths):
        """Traverse runtime references up to excluded boundaries and probe remote .narinfo."""
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
        phase_errors = {}

        if candidates:
            started = time.monotonic()
            sorted_candidates = sorted(candidates)
            with ThreadPoolExecutor(max_workers=self.query_concurrency) as pool:
                outcomes = list(pool.map(self._classify_path, sorted_candidates))

            query_elapsed = time.monotonic() - started
            for store_path, (verdict, source_uri, detail) in zip(sorted_candidates, outcomes):
                if verdict == "TARGET_HIT":
                    target_hits.add(store_path)
                elif verdict == "UPSTREAM_HIT":
                    upstream_hits.add(store_path)
                elif verdict == "MISS":
                    newly_pending[store_path] = candidates[store_path]
                elif verdict == "QUERY_ERROR":
                    # Refuse to upload paths when upstream availability could not be verified.
                    phase_errors[store_path] = [
                        {"cache": err_uri, "error": err_msg} for err_uri, err_msg in detail
                    ]
                    for err_uri, err_msg in detail:
                        self.query_failures[(err_uri, store_path)] = err_msg

            record(
                self.state,
                {
                    "kind": "cache-query",
                    "phase": self.phase,
                    "cache": ",".join(self.substituter_uris),
                    "candidates": len(sorted_candidates),
                    "seconds": query_elapsed,
                    "returncode": 1 if phase_errors else 0,
                    **(
                        {"errors": {p: errs for p, errs in phase_errors.items()}}
                        if phase_errors
                        else {}
                    ),
                },
            )

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
                "queryFailures": len(phase_errors),
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
                "queryFailures": phase_errors,
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

    def assert_no_query_failures(self):
        if self.query_failures:
            summary = "; ".join(
                f"{path} ({uri}: {msg})"
                for (uri, path), msg in sorted(self.query_failures.items())[:10]
            )
            raise RuntimeError(
                f"Refused cache upload due to {len(self.query_failures)} unverified upstream narinfo error(s): {summary}"
            )

    def upload(self, *, drain):
        settings = self.configuration
        # Pass an unmatchable pattern ('a^') to disable oranc's default
        # '^cache\.nixos\.org-.*$' exclusion so locally signed paths missing on
        # remote caches are uploaded.
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
        for name, parallel, group in groups:
            if not group:
                continue
            started = time.monotonic()
            result = subprocess.run(
                [*command, "--parallel", str(parallel)],
                input="".join(path + "\n" for path in group),
                text=True,
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
            if self.target_uri:
                with ThreadPoolExecutor(max_workers=self.query_concurrency) as pool:
                    verified = list(
                        pool.map(
                            lambda p: (
                                p,
                                *self._probe_substituter(
                                    self.target_uri,
                                    p,
                                    bypass_cache=True,
                                    retry_on_miss=True,
                                ),
                            ),
                            group,
                        )
                    )
                unverified = [
                    f"{path} ({state}: {detail})"
                    for path, state, detail in verified
                    if state != "HIT"
                ]
                if unverified:
                    raise RuntimeError(
                        "Post-upload remote .narinfo verification failed on target cache: "
                        + "; ".join(unverified[:10])
                    )
            self.published.update(group)
            with self.query_lock:
                for path in group:
                    del self.pending[path]
            atomic_json(self.state / "published-paths.json", sorted(self.published))
        if drain:
            self.assert_no_query_failures()


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
    retry_delays=RETRY_DELAYS,
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
        "target_uri": cache_cfg.get("targetUri"),
        "read_substituters": cache_cfg.get("readSubstituters") or [],
        "trusted_public_keys": cache_cfg.get("trustedPublicKeys") or [],
        "oranc": oranc,
        "no_ssl": no_ssl,
        "large_nar_bytes": large_nar_bytes,
        "retry_delays": list(retry_delays),
    }


def start_publisher(
    state,
    inventory,
    *,
    public_key,
    registry,
    repository,
    read_substituters,
    trusted_public_keys,
    target_uri=None,
    oranc="oranc",
    no_ssl=False,
    large_nar_bytes=LARGE_NAR_BYTES,
    retry_delays=RETRY_DELAYS,
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
            "target_uri": target_uri,
            "read_substituters": list(read_substituters),
            "trusted_public_keys": list(trusted_public_keys),
            "oranc": oranc,
            "no_ssl": no_ssl,
            "large_nar_bytes": large_nar_bytes,
            "retry_delays": list(retry_delays),
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
            target_uri=cfg["target_uri"],
            read_substituters=cfg["read_substituters"],
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
