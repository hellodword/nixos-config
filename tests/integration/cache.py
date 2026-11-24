#!/usr/bin/env python3
"""Integration tests for local Ed25519 signature provenance, multi-source deduplication, and signed OCI cache publication."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from tests.support import ROOT

sys.path.insert(0, str(ROOT / "infra/ci"))
import build  # noqa: E402
import cache  # noqa: E402
import evaluate  # noqa: E402
import report  # noqa: E402

run_build, valid_paths = build.run_build, build.valid_paths
read_records, render = report.read_records, report.render


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, **kwargs).stdout


def verify(uri, roots, public):
    run([
        "nix",
        "store",
        "verify",
        "--store",
        uri,
        "--sigs-needed",
        "1",
        "--option",
        "narinfo-cache-negative-ttl",
        "0",
        "--option",
        "trusted-public-keys",
        public,
        "--option",
        "extra-trusted-public-keys",
        "",
        *roots,
    ])


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@contextmanager
def listening(command, port, log=None):
    process = subprocess.Popen(command, stdout=log or sys.stderr, stderr=log or sys.stderr)
    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError("cache service exited before listening")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("cache service did not become ready")
                time.sleep(0.1)
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


@contextmanager
def build_gate():
    entered, release = threading.Event(), threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            entered.set()
            self.send_response(200 if release.wait(240) else 504)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/continue", entered, release
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join()


@contextmanager
def publishing(state, inventory, *, secret, **settings):
    with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}):
        cache.start_publisher(state, inventory, **settings, large_nar_bytes=4096)
    try:
        yield
    except BaseException:
        if (state / "publisher.log").exists():
            print((state / "publisher.log").read_text(), file=sys.stderr)
        raise
    finally:
        cache.stop_publisher(state)


def checkpoint(state, phase, *, finish=False):
    run([
        sys.executable,
        str(ROOT / "infra/ci"),
        "cache",
        "checkpoint",
        "--state",
        str(state),
        "--phase",
        phase,
        *(["--finish"] if finish else []),
    ])


@contextmanager
def interrupted_download(origin):
    """Serve real cache metadata, then close each NAR response halfway through."""
    interruptions = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            headers = (
                {"Authorization": self.headers["Authorization"]}
                if "Authorization" in self.headers
                else {}
            )
            with urlopen(Request(origin + self.path, headers=headers), timeout=30) as response:
                content = response.read()
                self.send_response(response.status)
                for name, value in response.headers.items():
                    if name.lower() not in ("transfer-encoding", "connection", "content-length"):
                        self.send_header(name, value)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                if self.path.startswith("/nar/"):
                    interruptions.append(self.path)
                    content = content[: len(content) // 2]
                self.wfile.write(content)
                self.close_connection = True

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", interruptions
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def authenticated_recovery(
    work,
    entry,
    inventory,
    publisher_settings,
    target_uri,
    secret,
    shared_secret,
    shared_public,
    proxy_port,
    proxy_log,
):
    username, password = "synthetic", "synthetic-cache-token"
    credentials = {
        "ORANC_USERNAME": username,
        "ORANC_PASSWORD": password,
        "ORANC_SIGNING_KEY": shared_secret.read_text().strip(),
    }
    htpasswd = work / "htpasswd"
    htpasswd.write_text(
        "synthetic:$2y$05$.NdRFJroQ.3tRrXEUgXFgu9kRotvL5mnO58wyQmtOgaveSjL5z8Gq\n"
    )
    port = free_port()
    registry = f"127.0.0.1:{port}"
    configuration = work / "authenticated-registry.json"
    configuration.write_text(
        json.dumps({
            "version": 0.1,
            "log": {"level": "error"},
            "storage": {"filesystem": {"rootdirectory": str(work / "authenticated-registry")}},
            "http": {"addr": registry},
            "auth": {"htpasswd": {"realm": "synthetic", "path": str(htpasswd)}},
        })
    )
    netrc = work / "netrc"
    netrc.write_text(f"machine 127.0.0.1\nlogin {username}\npassword {password}\n")
    netrc.chmod(0o600)
    origin = f"http://127.0.0.1:{proxy_port}/{registry}/synthetic/source"
    output_path = entry["outputs"][0]
    with listening(["registry", "serve", str(configuration)], port):
        run(["nix", "build", "--no-link", entry["drv"] + "^*"])
        content = Path(output_path).read_bytes()
        with patch.dict(os.environ, credentials):
            push = [
                "oranc",
                "push",
                "--registry",
                registry,
                "--repository",
                "synthetic/source",
                "--no-ssl",
            ]
            run([*push, "initialize", "--priority", "41"])
            run([*push, "--no-closure"], input=(output_path + "\n").encode())
        run(["nix-store", "--delete", output_path])
        config = os.environ.get("NIX_CONFIG", "") + f"\nnetrc-file = {netrc}\n"
        config += (
            f"trusted-public-keys = {shared_public} {publisher_settings['public_key']}\n"
            "extra-trusted-public-keys =\n"
        )
        with patch.dict(os.environ, {"NIX_CONFIG": config}):
            # 1. Authenticated upstream substitution preserves verified signature and skips re-upload.
            auth_dedup_state = work / "auth-dedup"
            run(["nix", "copy", "--from", origin, output_path])
            assert Path(output_path).read_bytes() == content
            with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}):
                dedup_pub = cache.Publisher(
                    auth_dedup_state,
                    {
                        **publisher_settings,
                        "inventory": {
                            "outputs": [output_path],
                            "derivations": [],
                            "excluded": [],
                        },
                    },
                )
                dedup_pub.phase = "auth-dedup"
                dedup_pub.discover([output_path])
                assert not dedup_pub.pending, "authenticated upstream hit should not be re-uploaded"
                dedup_events = read_records(auth_dedup_state / "timings.jsonl")
                assert dedup_events[-1]["upstreamHits"] == 1, dedup_events

            # 2. Interrupted NAR download falls back to local build and publishes to target.
            run(["nix-store", "--delete", output_path])
            state = work / "recovery"
            with (
                interrupted_download(origin) as (uri, interruptions),
                publishing(state, inventory, secret=secret, **publisher_settings),
                patch.dict(
                    os.environ,
                    {
                        "NIX_CONFIG": config
                        + f"substituters = {uri}\nextra-substituters =\nfallback = true\ndownload-attempts = 1\n"
                    },
                ),
            ):
                run_build([entry], state=state, phase="dependencies")
                checkpoint(state, "recovery", finish=True)
                target = [
                    event
                    for event in read_records(state / "timings.jsonl")
                    if event["kind"] == "target"
                ][-1]
                assert interruptions and target["source"] == "executed" and target["success"], {
                    "interruptedDownloads": interruptions,
                    "target": target,
                }
                assert target["restoreSeconds"] is not None and target["restoreSeconds"] >= 0
                assert target["buildSeconds"] is not None and target["buildSeconds"] >= 0
                assert Path(output_path).read_bytes() == content
                assert output_path in json.loads((state / "published-paths.json").read_text())
                verify(target_uri, [output_path], publisher_settings["public_key"])

        logs = [
            proxy_log,
            state / "publisher.log",
            state / "timings.jsonl",
            *(state / "logs").rglob("*.log"),
        ]
        for path in logs:
            text = path.read_text()
            assert password not in text
            assert base64.b64encode(f"{username}:{password}".encode()).decode() not in text
    netrc.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nixpkgs-input", choices=["nixpkgs", "nixpkgs-remote"], default="nixpkgs")
    args = parser.parse_args()

    with evaluate.sanitized_nixpkgs_env() as clean_env, patch.dict(os.environ, clean_env, clear=True):
        _run_suite(args)


def _run_suite(args):
    # Verify production cache-config.nix renders expected scopes via infra.lib.cache.
    production_caches = json.loads(
        run([
            "nix",
            "eval",
            "--store",
            "dummy://",
            "--json",
            "--file",
            str(ROOT / "nix/cache-config.nix"),
            "--apply",
            "c: { inherit (c) publicSettings; localUri = c.local.uri; ciUri = c.ci.uri; }",
        ])
    )
    assert "https://cache.nixos.org" in production_caches["publicSettings"]["substituters"]
    assert production_caches["ciUri"].startswith("http://127.0.0.2:37515/")

    # Verify mkPolicy excludes BOTH an outer redistributable wrapper and its restricted unwrapped payload.
    wrapper_policy = json.loads(
        run([
            "nix",
            "eval",
            "--impure",
            "--json",
            "--expr",
            f"""
            let
              flake = builtins.getFlake ("git+file://" + toString {json.dumps(str(ROOT))});
              pkgs = import flake.inputs.{args.nixpkgs_input} {{
                system = "x86_64-linux";
                config.allowUnfree = true;
              }};
              lib = pkgs.lib;
              cacheLib = import {json.dumps(str(ROOT / "infra/nix/cache.nix"))};
              inner = pkgs.runCommand "synthetic-unfree-inner" {{
                meta.license = lib.licenses.unfree;
              }} "echo secret > $out";
              outer = pkgs.runCommand "synthetic-mit-wrapper" {{
                passthru.unwrapped = inner;
                meta.license = lib.licenses.mit;
              }} "ln -s ${{inner}} $out";
              pol = cacheLib.mkPolicy {{
                inherit lib;
                flakeOutPath = "/nix/store/00000000000000000000000000000000-source";
                candidates = [ outer ];
              }};
            in {{
              innerOut = toString inner;
              outerOut = toString outer;
              innerDrv = inner.drvPath;
              outerDrv = outer.drvPath;
              inherit (pol) excludedPaths excludedDerivations privateBuilds;
            }}
            """,
        ])
    )
    assert wrapper_policy["innerOut"] in wrapper_policy["excludedPaths"], wrapper_policy
    assert wrapper_policy["outerOut"] in wrapper_policy["excludedPaths"], wrapper_policy
    assert wrapper_policy["innerDrv"] in wrapper_policy["excludedDerivations"], wrapper_policy
    assert wrapper_policy["outerDrv"] in wrapper_policy["excludedDerivations"], wrapper_policy
    assert {item["drv"] for item in wrapper_policy["privateBuilds"]} == {
        wrapper_policy["innerDrv"],
        wrapper_policy["outerDrv"],
    }, wrapper_policy

    # Verify report.verify_results rejects missing/empty manifests and tracks duplicate-name distinct-drv entries.
    with tempfile.TemporaryDirectory(prefix="report-verify-contract-") as report_tmp:
        rroot = Path(report_tmp)
        empty_state = rroot / "missing-manifest"
        empty_state.mkdir()
        try:
            report.verify_results(empty_state)
        except RuntimeError as err:
            assert "manifest not found" in str(err).lower(), err
        else:
            raise AssertionError("verify_results accepted a directory without manifest.json")

        zero_state = rroot / "zero-targets"
        zero_state.mkdir()
        (zero_state / "manifest.json").write_text(json.dumps({"groups": []}))
        try:
            report.verify_results(zero_state)
        except RuntimeError as err:
            assert "no required ci targets" in str(err).lower(), err
        else:
            raise AssertionError("verify_results accepted an empty manifest")

        dup_state = rroot / "duplicate-names"
        dup_state.mkdir()
        drv_a = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-vscode-1.drv"
        drv_b = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-vscode-2.drv"
        out_a = ["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-vscode-1"]
        out_b = ["/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-vscode-2"]
        dup_manifest = {
            "groups": [
                {
                    "name": "private",
                    "required": True,
                    "vm": None,
                    "kvm": False,
                    "maxJobs": 1,
                    "entries": [
                        {"name": "vscode", "drv": drv_a, "outputs": out_a, "required": True, "vm": False},
                        {"name": "vscode", "drv": drv_b, "outputs": out_b, "required": True, "vm": False},
                    ],
                }
            ]
        }
        (dup_state / "manifest.json").write_text(json.dumps(dup_manifest))
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a1", "kind": "build-start", "started": "2026-01-01T00:00:00Z", "log": "logs/a1.log"})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a1", "kind": "target", "name": "vscode", "drv": drv_a, "outputs": out_a, "source": "failed", "success": False})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a1", "kind": "target", "name": "vscode", "drv": drv_b, "outputs": out_b, "source": "executed", "success": True})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a1", "kind": "build", "started": "2026-01-01T00:00:00Z", "seconds": 1.0, "returncode": 0})
        try:
            report.verify_results(dup_state)
        except RuntimeError as err:
            assert "vscode (aaaaaaaaaaaa)" in str(err), err
        else:
            raise AssertionError("second same-name target overwrote failed first target")

        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a2", "kind": "build-start", "started": "2026-01-01T00:01:00Z", "log": "logs/a2.log"})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a2", "kind": "target", "name": "vscode", "drv": drv_a, "outputs": out_a, "source": "executed", "success": True})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a2", "kind": "target", "name": "vscode", "drv": drv_b, "outputs": out_b, "source": "executed", "success": True})
        report.record(dup_state, {"pass": "candidate", "phase": "private", "attempt": "a2", "kind": "build", "started": "2026-01-01T00:01:00Z", "seconds": 1.0, "returncode": 0})
        report.verify_results(dup_state)

    with (
        tempfile.TemporaryDirectory(prefix="cache-integration-") as temporary,
        build_gate() as (gate_url, entered, release),
    ):
        work = Path(temporary)
        fixture_expr = (
            '''let
          pkgs = (builtins.getFlake ("git+file://" + toString ./.)).inputs.NIXPKGS_INPUT.legacyPackages.x86_64-linux;
          prefix = PREFIX;
          mkItem = suffix: content:
            pkgs.runCommand "${prefix}-${suffix}" {} ''
              printf '%s' ${pkgs.lib.escapeShellArg content} > $out
            '';
          child = mkItem "child" "synthetic project content";
          large = mkItem "large" (builtins.concatStringsSep "" (builtins.genList (_: "data") 2048));
          late = mkItem "late" "new result after registry interruption";
          recovered = pkgs.runCommand "${prefix}-recovered" {} ''
            printf 'result rebuilt after an interrupted cache download' > $out
          '';
          endPhaseItem = mkItem "end-phase" "end-of-phase publication payload";
          publicLocal = mkItem "public-local" "known public file cache signature";
          sharedOci = mkItem "shared-oci" "secondary OCI upstream cache hit";
          forgedSigned = mkItem "forged-signed" "locally signed with forged and rotated keys";
          buildInput = builtins.toFile "${prefix}-build-input" "build input";
          runtimeInput = mkItem "runtime-input" "runtime input";
          localOnly = pkgs.writeText "${prefix}-local-only" "standalone local wrapper";
          referencedLocal = pkgs.writeText "${prefix}-referenced-local" "runtime-referenced local config";
          mediumRegular = mkItem "medium-regular" (builtins.concatStringsSep "" (builtins.genList (_: "m") 1024));
          tinyRegular = mkItem "tiny-regular" "t";
          uncachedTarget = mkItem "uncached-target" "target not yet in cache";
          innerPayload = builtins.toFile "${prefix}-inner-payload" "restricted inner payload";
          excludedWrapper = builtins.toFile "${prefix}-excluded-wrapper" "exec ${innerPayload}";
          source = mkItem "source" "synthetic restricted content";
          restricted = pkgs.runCommand "${prefix}-restricted" {} "cp ${source} $out";
          bundle = pkgs.runCommand "${prefix}-bundle" {} "cp ${restricted} $out";
          driver = pkgs.runCommand "${prefix}-driver" {} ''
            test -s ${child}
            ${pkgs.curl}/bin/curl --fail --max-time 240 GATE_URL
            printf ready > $out
          '';
          failure = pkgs.runCommand "${prefix}-failed" {} ''
            mkdir -p $out/artifacts
            printf '{"fixture":"failed application network log"}' > $out/artifacts/network.json
            chmod 700 $out/artifacts
            chmod 600 $out/artifacts/network.json
            printf 'synthetic builder stdout\\n'
            printf 'synthetic builder stderr\\n' >&2
            exit 17
          '';
          root = pkgs.runCommand "${prefix}-result" {} ''
            test "$(cat ${driver})" = ready
            test "$(cat ${buildInput})" = 'build input'
            printf '%s' '${child}; ${large}; ${publicLocal}; ${sharedOci}; ${forgedSigned}; ${runtimeInput}; ${referencedLocal}; prepared: ${bundle}' > $out
          '';
        in builtins.mapAttrs (_: value: { path = value.outPath; drv = value.drvPath; })
          { inherit child large late recovered endPhaseItem publicLocal sharedOci forgedSigned runtimeInput localOnly referencedLocal mediumRegular tinyRegular uncachedTarget source restricted bundle driver root failure; }
          // {
            buildInput.path = buildInput;
            innerPayload.path = innerPayload;
            excludedWrapper.path = excludedWrapper;
            curlBin = { path = "${pkgs.curl}"; drv = pkgs.curl.drvPath; };
          }
        '''
            .replace("NIXPKGS_INPUT", args.nixpkgs_input)
            .replace("PREFIX", json.dumps(work.name))
            .replace("GATE_URL", json.dumps(gate_url))
        )
        fixture = json.loads(
            run(
                ["nix", "eval", "--no-update-lock-file", "--impure", "--json", "--expr", fixture_expr],
                cwd=ROOT,
            )
        )

        # Verify evaluation failure handling with exit 0 from nix-eval-jobs.
        evaluation_state = work / "evaluation"
        expression = (
            "{ valid = import "
            + fixture["child"]["drv"]
            + '; broken = throw "synthetic evaluation failure"; }'
        )
        try:
            evaluate.evaluate_jobs(
                ["nix-eval-jobs", "--workers", "1", "--max-memory-size", "512", "--impure", "--expr", expression],
                {"valid", "broken"},
                evaluation_state,
                cwd=ROOT,
            )
        except RuntimeError as error:
            assert "broken" in str(error), error
            rows = read_records(evaluation_state / "evaluation.jsonl")
            assert any(row.get("attr") == "broken" and row.get("error") for row in rows)
            assert any(row.get("attr") == "valid" and row.get("drvPath") for row in rows)
        else:
            raise AssertionError("an evaluation error was accepted as a successful inventory")

        def entry(name, **kwargs):
            return {
                "name": name,
                "drv": fixture[name]["drv"],
                "outputs": [fixture[name]["path"]],
                **kwargs,
            }

        state = work / "metrics"
        test = entry("root", vm=True)
        dependency_names = (
            "bundle",
            "driver",
            "child",
            "large",
            "publicLocal",
            "sharedOci",
            "forgedSigned",
        )
        dependencies = [entry(name) for name in dependency_names]
        manifest = {
            "roots": [
                fixture[name]["drv"]
                for name in ("root", "localOnly", "late", "recovered", "endPhaseItem")
            ],
            "groups": [
                {
                    "name": "dependencies",
                    "required": True,
                    "vm": None,
                    "kvm": False,
                    "maxJobs": 2,
                    "entries": dependencies,
                },
                {
                    "name": "vm-fixture",
                    "required": True,
                    "vm": "nixos",
                    "kvm": False,
                    "maxJobs": 1,
                    "entries": [test],
                },
            ],
            "cache": {
                "excludedPaths": [fixture[name]["path"] for name in ("source", "restricted")],
                "excludedDerivations": [fixture["restricted"]["drv"]],
                "bundles": [fixture["bundle"]["drv"]],
            },
        }
        state.mkdir()
        (state / "manifest.json").write_text(json.dumps(manifest))

        inventory = cache.prepare_inventory(manifest)
        assert {fixture[name]["path"] for name in ("source", "restricted", "bundle")} <= set(
            inventory["excluded"]
        )
        assert {fixture[name]["path"] for name in ("localOnly", "referencedLocal")}.isdisjoint(
            inventory["outputs"]
        )
        inventory["outputs"] = [
            path for path in inventory["outputs"] if f"-{work.name}-" in path
        ]
        inventory["derivations"] = [
            drv for drv in inventory["derivations"] if f"-{work.name}-" in drv
        ]

        try:
            # Seed external build tools, upstream caches, and local signature fixtures.
            run([
                "nix",
                "build",
                "--no-link",
                fixture["curlBin"]["drv"] + "^bin",
                *[
                    fixture[name]["drv"] + "^out"
                    for name in ("publicLocal", "sharedOci", "forgedSigned", "localOnly")
                ],
            ])

            os.environ["XDG_CACHE_HOME"] = str(work / "nix-client-cache")

            # Key 1: target cache key
            secret = work / "target.secret"
            secret.write_bytes(run(["nix", "key", "generate-secret", "--key-name", "synthetic-target-1"]))
            secret.chmod(0o600)
            public = run(["nix", "key", "convert-secret-to-public"], input=secret.read_bytes()).decode().strip()

            # Key 2: public file:// cache key
            upstream_secret = work / "upstream.secret"
            upstream_secret.write_bytes(
                run(["nix", "key", "generate-secret", "--key-name", "synthetic-public-1"])
            )
            upstream_secret.chmod(0o600)
            upstream_public = (
                run(["nix", "key", "convert-secret-to-public"], input=upstream_secret.read_bytes())
                .decode()
                .strip()
            )

            # Key 3: secondary shared OCI cache key (simulating core repo GHCR cache)
            shared_secret = work / "shared.secret"
            shared_secret.write_bytes(
                run(["nix", "key", "generate-secret", "--key-name", "synthetic-shared-oci-1"])
            )
            shared_secret.chmod(0o600)
            shared_public = (
                run(["nix", "key", "convert-secret-to-public"], input=shared_secret.read_bytes())
                .decode()
                .strip()
            )

            # Populate publicLocal into file:// public cache and verify file:// binary-cache
            # roundtrip preserves upstream signatures (matching CI's oranc bootstrap archive).
            public_uri = (work / "public-cache").as_uri()
            run([
                "nix",
                "copy",
                "--to",
                f"{public_uri}?secret-key={upstream_secret}&compression=none",
                fixture["publicLocal"]["path"],
            ])
            bootstrap_cache = work / "bootstrap-cache"
            run([
                "nix",
                "copy",
                "--to",
                f"{bootstrap_cache.as_uri()}?secret-key={upstream_secret}&compression=none",
                fixture["publicLocal"]["path"],
            ])
            run([
                "nix",
                "copy",
                "--to",
                f"{bootstrap_cache.as_uri()}?compression=none",
                fixture["forgedSigned"]["path"],
            ])
            run(["nix-store", "--delete", fixture["publicLocal"]["path"], fixture["forgedSigned"]["path"]])
            run([
                "nix",
                "copy",
                "--from",
                bootstrap_cache.as_uri(),
                "--no-check-sigs",
                fixture["publicLocal"]["path"],
                fixture["forgedSigned"]["path"],
            ])
            restored_info = cache.path_info([fixture["publicLocal"]["path"], fixture["forgedSigned"]["path"]])
            assert cache.classify_path_info_signature(
                fixture["publicLocal"]["path"],
                restored_info[fixture["publicLocal"]["path"]],
                cache.parse_trusted_public_keys([upstream_public]),
            ) == ("VALID", "synthetic-public-1")
            assert cache.classify_path_info_signature(
                fixture["forgedSigned"]["path"],
                restored_info[fixture["forgedSigned"]["path"]],
                cache.parse_trusted_public_keys([upstream_public]),
            ) == ("UNTRUSTED", None)
            run(["nix-store", "--delete", fixture["publicLocal"]["path"]])

            # Sign forgedSigned in local /nix/store with BOTH a forged key impersonating
            # cache.nixos.org-1 and a rotated-out old target key (synthetic-target-0).
            # In-memory Ed25519 verification against trusted_public_keys must reject both
            # and upload forgedSigned with the active target key.
            forged_nixos_org = work / "forged-nixos-org.secret"
            forged_nixos_org.write_bytes(
                run(["nix", "key", "generate-secret", "--key-name", "cache.nixos.org-1"])
            )
            forged_nixos_org.chmod(0o600)
            rotated_old_secret = work / "rotated-old.secret"
            rotated_old_secret.write_bytes(
                run(["nix", "key", "generate-secret", "--key-name", "synthetic-target-0"])
            )
            rotated_old_secret.chmod(0o600)
            for key_file in (forged_nixos_org, rotated_old_secret):
                run([
                    "nix",
                    "store",
                    "sign",
                    "--key-file",
                    str(key_file),
                    fixture["forgedSigned"]["path"],
                ])

            registry_port, proxy_port = free_port(), free_port()
            configuration = work / "registry.json"
            configuration.write_text(
                json.dumps({
                    "version": 0.1,
                    "log": {"level": "error"},
                    "storage": {"filesystem": {"rootdirectory": str(work / "registry")}},
                    "http": {"addr": f"127.0.0.1:{registry_port}"},
                })
            )
            proxy_log = work / "oranc.log"
            with (
                patch.dict(os.environ, {"RUST_LOG": "oranc=info,oranc::registry=debug"}),
                proxy_log.open("w") as log,
                listening(["registry", "serve", str(configuration)], registry_port) as registry_process,
                listening(
                    ["oranc", "server", "--no-ssl", "--listen", f"127.0.0.1:{proxy_port}"],
                    proxy_port,
                    log,
                ),
            ):
                shared_uri = (
                    f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/shared-core"
                )
                target_uri = (
                    f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/cache-test"
                )

                # Uninitialized OCI repository returns HTTP 404 on /nix-cache-info (relied on by action.yml).
                try:
                    urlopen(target_uri + "/nix-cache-info", timeout=10)
                except HTTPError as http_err:
                    assert http_err.code == 404, http_err.code
                else:
                    raise AssertionError("uninitialized OCI repository unexpectedly returned 200")

                # Initialize both secondary shared OCI cache and target OCI cache.
                for repo_name in ("synthetic/shared-core", "synthetic/cache-test"):
                    run([
                        "oranc",
                        "push",
                        "--registry",
                        f"127.0.0.1:{registry_port}",
                        "--repository",
                        repo_name,
                        "--no-ssl",
                        "initialize",
                        "--priority",
                        "41",
                    ])

                # Upload sharedOci ONLY to secondary shared OCI cache, then delete its local
                # store path so nix build substitutes it with a verified upstream signature.
                with patch.dict(os.environ, {"ORANC_SIGNING_KEY": shared_secret.read_text().strip()}):
                    run(
                        [
                            "oranc",
                            "push",
                            "--registry",
                            f"127.0.0.1:{registry_port}",
                            "--repository",
                            "synthetic/shared-core",
                            "--no-ssl",
                            "--no-closure",
                        ],
                        input=(fixture["sharedOci"]["path"] + "\n").encode(),
                    )
                run(["nix-store", "--delete", fixture["sharedOci"]["path"]])

                with urlopen(target_uri + "/nix-cache-info", timeout=10) as response:
                    assert b"StoreDir: /nix/store" in response.read()

                read_substituters = [public_uri, shared_uri, target_uri]
                real_nixos_org_key = (
                    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                )
                trusted_public_keys = [
                    real_nixos_org_key,
                    upstream_public,
                    shared_public,
                    public,
                ]
                publisher_settings = dict(
                    public_key=public,
                    registry=f"127.0.0.1:{registry_port}",
                    repository="synthetic/cache-test",
                    trusted_public_keys=trusted_public_keys,
                    no_ssl=True,
                )
                client_nix_config = (
                    os.environ.get("NIX_CONFIG", "")
                    + f"\nsubstituters = {' '.join(read_substituters)}\n"
                    + "extra-substituters =\n"
                    + f"trusted-public-keys = {' '.join(trusted_public_keys)}\n"
                    + "extra-trusted-public-keys =\n"
                    + "require-sigs = true\n"
                    + "narinfo-cache-negative-ttl = 0\n"
                )

                # 1. Incremental publication during live build + error reporting + checkpoints.
                with (
                    patch.dict(os.environ, {"NIX_CONFIG": client_nix_config}),
                    publishing(state, inventory, secret=secret, **publisher_settings),
                ):
                    run_build([entry("large")], state=state, phase="preparation")
                    annotations = io.StringIO()
                    with ThreadPoolExecutor(max_workers=1) as pool, redirect_stderr(annotations):
                        future = pool.submit(
                            run_build,
                            [*dependencies, entry("failure")],
                            state=state,
                            phase="dependencies",
                            jobs=2,
                            github_actions=True,
                        )
                        try:
                            assert entered.wait(180), "the dependent build did not reach its gate"
                            deadline = time.monotonic() + 120
                            receipt = state / "published-paths.json"
                            while not receipt.exists() or fixture["child"]["path"] not in json.loads(
                                receipt.read_text()
                            ):
                                status = json.loads((state / "cache/status.json").read_text())
                                assert status["result"] == "running", status
                                assert time.monotonic() < deadline, (
                                    "completed dependency was not published during the build"
                                )
                                time.sleep(0.2)
                            verify(target_uri, [fixture["child"]["path"]], public)
                            while not (
                                errors := [
                                    event
                                    for event in read_records(state / "timings.jsonl")
                                    if event["kind"] == "build-error"
                                ]
                            ):
                                assert time.monotonic() < deadline, (
                                    "build failure was not reported while the peer was running"
                                )
                                time.sleep(0.1)
                            while "::error::" not in annotations.getvalue():
                                assert time.monotonic() < deadline, "Actions error annotation was not emitted"
                                time.sleep(0.1)
                            assert errors[0]["phase"] == "dependencies"
                            while True:
                                retained = (state / errors[0]["log"]).read_text()
                                if (
                                    "synthetic builder stdout" in retained
                                    and "synthetic builder stderr" in retained
                                ):
                                    break
                                assert time.monotonic() < deadline
                                time.sleep(0.1)
                            assert not future.done()
                            assert fixture["large"]["path"] not in json.loads(receipt.read_text())
                        finally:
                            release.set()

                        try:
                            future.result()
                        except RuntimeError:
                            assert valid_paths(
                                [fixture[name]["path"] for name in dependency_names]
                            ) == {fixture[name]["path"] for name in dependency_names}
                        else:
                            raise AssertionError("synthetic failing build unexpectedly succeeded")

                    assert valid_paths([fixture["root"]["path"]]) == set()
                    checkpoint(state, "dependencies")
                    first = set(json.loads(receipt.read_text()))
                    # child, large, driver, and forgedSigned (forged cache.nixos.org-1 + rotated-out key)
                    # are published, while publicLocal and sharedOci were substituted with trusted
                    # upstream signatures and skipped as upstreamHits.
                    expected_first = {
                        fixture[name]["path"]
                        for name in ("child", "large", "driver", "forgedSigned")
                    }
                    assert first == expected_first, {"actual": first, "expected": expected_first}
                    verify(target_uri, first, public)

                    # Build root VM fixture & verify classification labels.
                    run_build([test], state=state, phase="vm-fixture")
                    # Re-run clean dependencies attempt so all required groups succeeded before verify_results:
                    run_build(dependencies, state=state, phase="dependencies")
                    report.verify_results(state, "candidate")

                    run_build([test], state=state, phase="vm-fixture", pass_name="committed")
                    vm_by_pass = {
                        event["pass"]: event
                        for event in read_records(state / "timings.jsonl")
                        if event.get("vm")
                    }
                    assert (
                        vm_by_pass["candidate"]["source"] == "executed"
                        and vm_by_pass["candidate"]["success"]
                        and vm_by_pass["candidate"]["buildSeconds"] is not None
                        and vm_by_pass["candidate"]["buildSeconds"] >= 0
                    )
                    assert (
                        vm_by_pass["committed"]["source"] == "local reuse"
                        and vm_by_pass["committed"]["success"]
                        and vm_by_pass["committed"]["buildSeconds"] is None
                    )

                    # Failed retry must supersede earlier success and collect VM failure evidence with 0755/0644 modes.
                    failed = entry("failure", vm=True) | {"name": test["name"]}
                    try:
                        run_build([failed], state=state, phase="vm-fixture")
                    except RuntimeError:
                        pass
                    else:
                        raise AssertionError("the retry should fail")
                    events = read_records(state / "timings.jsonl")
                    failed_attempt = [event for event in events if event["kind"] == "build"][-1]
                    assert failed_attempt["returncode"] != 0
                    failed_evidence = next(
                        event
                        for event in events
                        if event["kind"] == "vm-evidence" and event["attempt"] == failed_attempt["attempt"]
                    )
                    retained = state / failed_evidence["path"] / Path(failed["outputs"][0]).name
                    assert json.loads((retained / "artifacts/network.json").read_text()) == {
                        "fixture": "failed application network log"
                    }
                    assert (retained / "artifacts").stat().st_mode & 0o777 == 0o755
                    assert (retained / "artifacts/network.json").stat().st_mode & 0o777 == 0o644
                    try:
                        report.verify_results(state, "candidate")
                    except RuntimeError:
                        pass
                    else:
                        raise AssertionError("previous success hid latest failed retry")

                    run_build([test], state=state, phase="vm-fixture")
                    report.verify_results(state, "candidate")

                    checkpoint(state, "results", finish=True)
                    published_incremental = set(json.loads(receipt.read_text()))
                    assert published_incremental - first == {
                        fixture[name]["path"] for name in ("root", "runtimeInput", "referencedLocal")
                    }
                    assert fixture["localOnly"]["path"] not in published_incremental
                    verify(target_uri, [fixture["root"]["path"]], public)
                    events = read_records(state / "timings.jsonl")
                    publications = [event for event in events if event["kind"] == "publication"]
                    path_records = read_records(state / "publication-paths.jsonl")
                    excluded_paths = {
                        path
                        for row in path_records
                        if row["stage"] == "selection"
                        for path in row["excluded"]
                    }
                    upstream_hit_paths = {
                        path
                        for row in path_records
                        if row["stage"] == "upload"
                        for path in row["upstreamHits"]
                    }
                    assert excluded_paths == {
                        fixture[name]["path"] for name in ("source", "restricted", "bundle")
                    }
                    assert upstream_hit_paths == {
                        fixture[name]["path"] for name in ("publicLocal", "sharedOci")
                    }
                    assert sum(event["excluded"] for event in publications) == len(excluded_paths)
                    assert sum(event["upstreamHits"] for event in publications) == len(upstream_hit_paths)

                # 2. Wrapper reference truncation test.
                wrapper_state = work / "wrapper-exclusion"
                wrapper_state.mkdir()
                with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}):
                    wrapper_publisher = cache.Publisher(
                        wrapper_state,
                        {
                            "inventory": {
                                "outputs": [fixture["excludedWrapper"]["path"]],
                                "derivations": [],
                                "excluded": [fixture["excludedWrapper"]["path"]],
                            },
                            **publisher_settings,
                        },
                    )
                    wrapper_publisher.discover([fixture["excludedWrapper"]["path"]])
                assert fixture["innerPayload"]["path"] not in wrapper_publisher.seen
                assert not wrapper_publisher.pending

                # 3. End-of-phase single-shot mode (`publish_once` / `nix-ci cache publish`) parity
                #    after clean-store substitution of previously published paths + fresh build of endPhaseItem.
                run([
                    "nix-store",
                    "--delete",
                    *[
                        fixture[name]["path"]
                        for name in (
                            "root",
                            "driver",
                            "child",
                            "large",
                            "forgedSigned",
                            "runtimeInput",
                            "referencedLocal",
                            "publicLocal",
                            "sharedOci",
                        )
                    ],
                ])
                with patch.dict(os.environ, {"NIX_CONFIG": client_nix_config}):
                    run([
                        "nix",
                        "build",
                        "--no-link",
                        fixture["root"]["drv"] + "^*",
                        fixture["driver"]["drv"] + "^*",
                        fixture["endPhaseItem"]["drv"] + "^*",
                    ])

                eop_state = work / "end-of-phase"
                eop_manifest = {
                    "roots": [
                        fixture["root"]["drv"],
                        fixture["localOnly"]["drv"],
                        fixture["endPhaseItem"]["drv"],
                    ],
                    "cache": {
                        "registry": f"127.0.0.1:{registry_port}",
                        "repository": "synthetic/cache-test",
                        "publicKey": public,
                        "mode": "end-of-phase",
                        "targetUri": target_uri,
                        "readSubstituters": read_substituters,
                        "trustedPublicKeys": trusted_public_keys,
                        "excludedPaths": [fixture[name]["path"] for name in ("source", "restricted")],
                        "excludedDerivations": [fixture["restricted"]["drv"]],
                        "bundles": [fixture["bundle"]["drv"]],
                    },
                }
                eop_state.mkdir()
                eop_cfg = cache.build_publisher_configuration(eop_manifest, no_ssl=True)
                eop_cfg["inventory"]["outputs"] = [
                    path for path in eop_cfg["inventory"]["outputs"] if f"-{work.name}-" in path
                ]
                with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text()}):
                    eop_published = cache.publish_once(eop_state, eop_cfg, phase="end-of-phase")
                assert eop_published == [fixture["endPhaseItem"]["path"]], eop_published
                eop_pubs = [
                    e for e in read_records(eop_state / "timings.jsonl") if e["kind"] == "publication"
                ]
                eop_path_records = read_records(eop_state / "publication-paths.jsonl")
                eop_upstream_paths = {
                    path
                    for row in eop_path_records
                    if row["stage"] == "upload"
                    for path in row["upstreamHits"]
                }
                eop_target_paths = {
                    path
                    for row in eop_path_records
                    if row["stage"] == "upload"
                    for path in row["targetHits"]
                }
                assert eop_upstream_paths == {
                    fixture[name]["path"] for name in ("publicLocal", "sharedOci")
                }
                assert eop_target_paths == {
                    fixture[name]["path"]
                    for name in (
                        "root",
                        "driver",
                        "child",
                        "large",
                        "forgedSigned",
                        "runtimeInput",
                        "referencedLocal",
                    )
                }
                assert sum(e["upstreamHits"] for e in eop_pubs) == len(eop_upstream_paths)
                assert sum(e["targetHits"] for e in eop_pubs) == len(eop_target_paths)

                # 4. Clean store restoration across ALL THREE caches (file:// public, shared OCI, target OCI)
                #    via infra/scripts/nix-cache.sh install, followed by a zero-upload verification pass.
                restore_paths = [
                    fixture[name]["path"]
                    for name in (
                        "root",
                        "driver",
                        "child",
                        "large",
                        "forgedSigned",
                        "runtimeInput",
                        "referencedLocal",
                        "endPhaseItem",
                        "publicLocal",
                        "sharedOci",
                    )
                ]
                expected_bytes = {path: Path(path).read_bytes() for path in restore_paths}
                run(["nix-store", "--delete", *restore_paths])

                client = work / "client"
                (client / "nix").mkdir(parents=True)
                custom_cache_nix = client / "nix/cache-config.nix"
                custom_cache_nix.write_text(
                    f"""
                    let
                      cacheLib = import {json.dumps(str(ROOT / "infra/nix/cache.nix"))};
                    in
                    cacheLib.mkCacheConfig {{
                      target = {{
                        registry = "127.0.0.1:{registry_port}";
                        repository = "synthetic/cache-test";
                        publicKey = {json.dumps(public)};
                      }};
                      extraRepositories = [
                        {{
                          registry = "127.0.0.1:{registry_port}";
                          repository = "synthetic/shared-core";
                          publicKey = {json.dumps(shared_public)};
                        }}
                      ];
                      listenAddress = "127.0.0.1";
                      port = {proxy_port};
                      publicDefaults = {{
                        substituters = [ {json.dumps(public_uri)} ];
                        trusted-public-keys = [ {json.dumps(upstream_public)} ];
                      }};
                    }}
                    """
                )
                config_home = work / "config"
                nix_conf = config_home / "nix/nix.conf"
                nix_conf.parent.mkdir(parents=True)
                nix_conf.write_text("# Existing client settings\nconnect-timeout = 7\nsandbox-fallback = true\n")
                with patch.dict(
                    os.environ,
                    {
                        "XDG_CACHE_HOME": str(work / "restored-client-cache"),
                        "XDG_CONFIG_HOME": str(config_home),
                        "NIX_USER_CONF_FILES": str(nix_conf),
                    },
                ):
                    run([
                        "bash",
                        str(ROOT / "infra/scripts/nix-cache.sh"),
                        "install",
                        "--config-file",
                        str(custom_cache_nix),
                        "--fragment-name",
                        "nixos-config-cache.conf",
                    ])
                    run([
                        "bash",
                        str(ROOT / "infra/scripts/nix-cache.sh"),
                        "install",
                        "--config-file",
                        str(custom_cache_nix),
                        "--fragment-name",
                        "nixos-config-cache.conf",
                    ])
                    lines = nix_conf.read_text().splitlines()
                    assert "# Existing client settings" in lines
                    assert lines.count("include nixos-config-cache.conf") == 1
                    settings = json.loads(run(["nix", "config", "show", "--json"]))
                    assert settings["connect-timeout"]["value"] == 7
                    assert target_uri in settings["substituters"]["value"]
                    assert shared_uri in settings["substituters"]["value"]
                    assert public_uri in settings["substituters"]["value"]
                    assert settings["require-sigs"]["value"]

                    run_build(
                        [test, entry("driver"), entry("endPhaseItem")],
                        state=state,
                        phase="vm-fixture",
                        pass_name="restored",
                    )

                restored_vm = [
                    event for event in read_records(state / "timings.jsonl") if event.get("vm")
                ][-1]
                assert restored_vm["source"] == "cache restored" and restored_vm["success"]
                assert (
                    restored_vm["buildSeconds"] is None
                    and restored_vm["restoreSeconds"] is not None
                    and restored_vm["restoreSeconds"] >= 0
                )
                assert all(Path(path).read_bytes() == content for path, content in expected_bytes.items())

                zero_dup_state = work / "post-restore-zero-upload"
                with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}):
                    re_published = cache.publish_once(zero_dup_state, eop_cfg, phase="post-restore")
                assert re_published == [], f"Expected zero duplicate uploads after restore, got {re_published}"
                assert not (zero_dup_state / "published-paths.json").exists()

                # 4b. Background priority uploads larger regular artifacts ahead of smaller ones,
                #     and `prepares` skips driver realization when its downstream target is cached.
                run([
                    "nix",
                    "build",
                    "--no-link",
                    fixture["mediumRegular"]["drv"] + "^out",
                    fixture["tinyRegular"]["drv"] + "^out",
                ])
                priority_state = work / "background-priority"
                with (
                    patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}),
                    patch.object(cache, "BACKGROUND_BATCH", 1),
                ):
                    priority_pub = cache.Publisher(
                        priority_state,
                        {
                            "inventory": {
                                "outputs": [
                                    fixture["mediumRegular"]["path"],
                                    fixture["tinyRegular"]["path"],
                                ],
                                "derivations": [],
                                "excluded": [],
                            },
                            **publisher_settings,
                        },
                    )
                    priority_pub.reconcile()
                    priority_pub.upload(drain=False)
                    assert priority_pub.published == {fixture["mediumRegular"]["path"]}
                    assert set(priority_pub.pending) == {fixture["tinyRegular"]["path"]}

                run(["nix-store", "--delete", fixture["root"]["path"], fixture["driver"]["path"]])
                prepares_project = work / "prepares-project"
                (prepares_project / "nix").mkdir(parents=True, exist_ok=True)
                (prepares_project / "flake.nix").write_text(
                    "{\n"
                    "  outputs = { self }: {\n"
                    '    outPath = builtins.storePath "' + fixture["endPhaseItem"]["path"] + '";\n'
                    "  };\n"
                    "}\n"
                )
                (prepares_project / "nix/ci.nix").write_text(
                    "{ flake, system ? \"x86_64-linux\", select ? {} }: {\n"
                    "  jobs = {\n"
                    "    cached-vm = import " + json.dumps(fixture["root"]["drv"]) + ";\n"
                    "    cached-vm-driver = import " + json.dumps(fixture["driver"]["drv"]) + ";\n"
                    "    uncached-vm = import " + json.dumps(fixture["uncachedTarget"]["drv"]) + ";\n"
                    "    uncached-vm-driver = import " + json.dumps(fixture["tinyRegular"]["drv"]) + ";\n"
                    "  };\n"
                    "  groups = [\n"
                    "    {\n"
                    "      name = \"drivers\";\n"
                    "      jobs = [\n"
                    "        { job = \"cached-vm-driver\"; prepares = \"cached-vm\"; }\n"
                    "        { job = \"uncached-vm-driver\"; prepares = \"uncached-vm\"; }\n"
                    "      ];\n"
                    "      required = true; vm = null; kvm = false; maxJobs = 1;\n"
                    "    }\n"
                    "    {\n"
                    "      name = \"vms\";\n"
                    "      jobs = [ \"cached-vm\" \"uncached-vm\" ];\n"
                    "      required = true; vm = \"nixos\"; kvm = false; maxJobs = 1;\n"
                    "    }\n"
                    "  ];\n"
                    "  cache = null;\n"
                    "  update = null;\n"
                    "}\n"
                )
                run(["nix-store", "--delete", fixture["tinyRegular"]["path"]])
                prepares_state = work / "prepares-state"
                evaluate.evaluate_manifest(project_dir=prepares_project, state=prepares_state)
                with patch.dict(os.environ, {"NIX_CONFIG": client_nix_config}):
                    build.build_group(state=prepares_state, group_name="drivers")
                    assert valid_paths([fixture["driver"]["path"]]) == set()
                    assert valid_paths([fixture["tinyRegular"]["path"]]) == {fixture["tinyRegular"]["path"]}
                    build.build_group(state=prepares_state, group_name="vms")
                prepares_targets = {
                    event["name"]: event
                    for event in read_records(prepares_state / "timings.jsonl")
                    if event["kind"] == "target"
                }
                assert prepares_targets["cached-vm-driver"]["source"] == "cache restored"
                assert prepares_targets["uncached-vm-driver"]["source"] == "executed"
                assert prepares_targets["cached-vm"]["source"] == "cache restored"
                assert prepares_targets["uncached-vm"]["source"] == "executed"
                report.verify_results(prepares_state)

                # 5. Authenticated recovery & interrupted NAR fallback.
                authenticated_recovery(
                    work,
                    entry("recovered"),
                    inventory,
                    publisher_settings,
                    target_uri,
                    secret,
                    shared_secret,
                    shared_public,
                    proxy_port,
                    proxy_log,
                )

                # 6. Concurrent Nix build lock wait classifies waiter as concurrent reuse (never local reuse)
                #    and non-Git path: directory evaluate_manifest succeeds.
                concurrent_token = f"{work.name}-concurrent-{time.time_ns()}"
                with build_gate() as (conc_url, conc_entered, conc_release):
                    concurrent_info = json.loads(
                        run(
                            [
                                "nix",
                                "eval",
                                "--no-update-lock-file",
                                "--impure",
                                "--json",
                                "--expr",
                                (
                                    "let pkgs = (builtins.getFlake ("
                                    + json.dumps("git+file://" + str(ROOT))
                                    + ")).inputs."
                                    + args.nixpkgs_input
                                    + ".legacyPackages.x86_64-linux;"
                                    + " d = pkgs.runCommand "
                                    + json.dumps(concurrent_token)
                                    + " {} ''"
                                    + "${pkgs.curl}/bin/curl --fail --max-time 60 "
                                    + json.dumps(conc_url)
                                    + "; printf concurrent > $out"
                                    + "'';"
                                    + " in { drv = d.drvPath; out = d.outPath; }"
                                ),
                            ],
                            cwd=ROOT,
                        )
                    )
                    concurrent_entry = {
                        "name": "concurrent-item",
                        "drv": concurrent_info["drv"],
                        "outputs": [concurrent_info["out"]],
                        "required": True,
                        "vm": False,
                    }
                    state_builder = work / "concurrent-builder"
                    state_waiter = work / "concurrent-waiter"
                    for st in (state_builder, state_waiter):
                        st.mkdir(parents=True, exist_ok=True)
                        (st / "manifest.json").write_text(
                            json.dumps(
                                {
                                    "groups": [
                                        {
                                            "name": "concurrent",
                                            "required": True,
                                            "vm": None,
                                            "kvm": False,
                                            "maxJobs": 1,
                                            "entries": [concurrent_entry],
                                        }
                                    ],
                                }
                            )
                        )
                    builder_errors, waiter_errors = [], []

                    def _run_primary():
                        try:
                            run_build([concurrent_entry], state=state_builder, phase="concurrent")
                        except BaseException as exc:
                            builder_errors.append(exc)

                    def _run_waiter():
                        try:
                            run_build([concurrent_entry], state=state_waiter, phase="concurrent")
                        except BaseException as exc:
                            waiter_errors.append(exc)

                    primary_thread = threading.Thread(target=_run_primary)
                    waiter_thread = threading.Thread(target=_run_waiter)
                    try:
                        primary_thread.start()
                        assert conc_entered.wait(60), "primary build did not reach gate"
                        waiter_thread.start()
                        waiter_deadline = time.monotonic() + 60
                        while not list(state_waiter.glob("nix-events-*.jsonl")):
                            assert not waiter_errors, waiter_errors
                            assert time.monotonic() < waiter_deadline, "waiter build did not initialize"
                            time.sleep(0.05)
                    finally:
                        conc_release.set()
                    primary_thread.join(timeout=30)
                    waiter_thread.join(timeout=30)
                assert not builder_errors, builder_errors
                assert not waiter_errors, waiter_errors
                primary_target = [
                    e for e in read_records(state_builder / "timings.jsonl") if e["kind"] == "target"
                ][-1]
                waiter_target = [
                    e for e in read_records(state_waiter / "timings.jsonl") if e["kind"] == "target"
                ][-1]
                assert primary_target["source"] == "executed" and primary_target["success"], primary_target
                assert waiter_target["source"] == "concurrent reuse" and waiter_target["success"], waiter_target
                report.verify_results(state_builder)
                report.verify_results(state_waiter)

                non_git_project = work / "non-git-project"
                (non_git_project / "nix").mkdir(parents=True, exist_ok=True)
                (non_git_project / "flake.nix").write_text(
                    "{\n"
                    "  outputs = { self }: {\n"
                    '    outPath = builtins.storePath "' + concurrent_info["out"] + '";\n'
                    "  };\n"
                    "}\n"
                )
                (non_git_project / "nix/ci.nix").write_text(
                    "{ flake, system ? \"x86_64-linux\", select ? {} }: {\n"
                    "  jobs = { sample = import " + json.dumps(concurrent_info["drv"]) + "; };\n"
                    "  groups = [ { name = \"build\"; jobs = [ \"sample\" ]; required = true; vm = null; kvm = false; maxJobs = 1; } ];\n"
                    "  cache = null;\n"
                    "  update = { allowedLockfiles = [ \"flake.lock\" ]; ignoreOnlyInputs = []; commitTitle = \"chore: update\"; branchPrefix = \"auto/upd\"; };\n"
                    "}\n"
                )
                non_git_state = work / "non-git-state"
                non_git_manifest = evaluate.evaluate_manifest(
                    project_dir=non_git_project,
                    state=non_git_state,
                )
                assert len(non_git_manifest["groups"][0]["entries"]) == 1, non_git_manifest

                # 7. Ensure evaluate_manifest strips ambient NIXPKGS_ALLOW_UNFREE / NIXPKGS_CONFIG.
                nixpkgs_out = (
                    run(
                        [
                            "nix",
                            "eval",
                            "--no-update-lock-file",
                            "--impure",
                            "--raw",
                            "--expr",
                            f'(builtins.getFlake ("git+file://" + toString ./. )).inputs.{args.nixpkgs_input}.outPath',
                        ],
                        cwd=ROOT,
                    )
                    .decode()
                    .strip()
                )
                unfree_leak_project = work / "unfree-leak-project"
                (unfree_leak_project / "nix").mkdir(parents=True, exist_ok=True)
                (unfree_leak_project / "flake.nix").write_text(
                    "{\n"
                    "  outputs = { self }: {\n"
                    '    outPath = builtins.storePath "' + concurrent_info["out"] + '";\n'
                    "  };\n"
                    "}\n"
                )
                (unfree_leak_project / "nix/ci.nix").write_text(
                    "{ flake, system ? \"x86_64-linux\", select ? {} }:\n"
                    "let\n"
                    "  pkgs = import (builtins.storePath " + json.dumps(nixpkgs_out) + ") { inherit system; };\n"
                    "in {\n"
                    "  jobs = { sample = import " + json.dumps(concurrent_info["drv"]) + "; };\n"
                    "  groups = [ { name = \"build\"; jobs = [ \"sample\" ]; required = true; vm = null; kvm = false; maxJobs = 1; } ];\n"
                    "  cache = {\n"
                    "    repository = \"synthetic/unfree-leak\";\n"
                    "    publicKey = \"synthetic-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\";\n"
                    "    mode = \"end-of-phase\";\n"
                    "    excludedPaths = [ (toString pkgs.vscode) ];\n"
                    "    excludedDerivations = [];\n"
                    "    bundles = [];\n"
                    "    privateBuilds = [];\n"
                    "  };\n"
                    "  update = null;\n"
                    "}\n"
                )
                permissive_cfg = work / "permissive-nixpkgs-config.nix"
                permissive_cfg.write_text("{ allowUnfree = true; }\n")
                with patch.dict(
                    os.environ,
                    {
                        "NIXPKGS_ALLOW_UNFREE": "1",
                        "NIXPKGS_CONFIG": str(permissive_cfg),
                    },
                ):
                    try:
                        evaluate.evaluate_manifest(
                            project_dir=unfree_leak_project,
                            state=work / "unfree-leak-state",
                        )
                    except subprocess.CalledProcessError:
                        pass
                    else:
                        raise AssertionError(
                            "evaluate_manifest allowed unconfigured legacyPackages unfree package via ambient NIXPKGS_*"
                        )

                # 8. Target registry outage during upload propagates failure cleanly.
                failure_state = work / "publication-failure"
                with publishing(failure_state, inventory, secret=secret, **publisher_settings):
                    checkpoint(failure_state, "ready")
                    registry_process.terminate()
                    registry_process.wait(timeout=10)
                    run_build([entry("late")], state=failure_state, phase="new-output")
                    try:
                        checkpoint(failure_state, "unavailable-registry", finish=True)
                    except subprocess.CalledProcessError:
                        status = json.loads((failure_state / "cache/status.json").read_text())
                        assert status["result"] == "failure", status
                        failure_events = read_records(failure_state / "timings.jsonl")
                        assert any(
                            event["kind"] == "cache-upload" and event["returncode"] != 0
                            for event in failure_events
                        )
                        assert any(
                            event["kind"] == "cache-error" and event["phase"] == "unavailable-registry"
                            for event in failure_events
                        )
                        assert any(
                            event["kind"] == "cache-checkpoint"
                            and event["phase"] == "unavailable-registry"
                            and event["returncode"] != 0
                            for event in failure_events
                        )
                    else:
                        raise AssertionError("publication succeeded with an unavailable registry")

                push_fail_state = work / "push-failure"
                with patch.dict(os.environ, {"ORANC_SIGNING_KEY": secret.read_text().strip()}):
                    try:
                        cache.publish_once(
                            push_fail_state,
                            {
                                "inventory": {
                                    "outputs": [fixture["late"]["path"]],
                                    "derivations": [Path(fixture["late"]["drv"]).name],
                                    "excluded": [],
                                },
                                **publisher_settings,
                            },
                            phase="push-unavailable-registry",
                        )
                    except subprocess.CalledProcessError:
                        push_fail_events = read_records(push_fail_state / "timings.jsonl")
                        assert any(
                            event["kind"] == "cache-upload" and event["returncode"] != 0
                            for event in push_fail_events
                        )
                        assert any(
                            event["kind"] == "cache-error"
                            and event["phase"] == "push-unavailable-registry"
                            for event in push_fail_events
                        )
                    else:
                        raise AssertionError("oranc push succeeded with an unavailable registry")

            rendered_summary = render(state)
            assert "Queries" not in rendered_summary
            print(rendered_summary)
        finally:
            candidates = sorted(
                str(path) for path in Path("/nix/store").glob(f"*-{work.name}-*")
            )
            if candidates:
                subprocess.run(
                    ["nix-store", "--delete", *candidates],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

    print(
        json.dumps({
            "result": "passed",
            "nixpkgsInput": args.nixpkgs_input,
            "scenarios": [
                "infra.lib.cache mkCacheConfig and mkPolicy evaluation",
                "local path-info Ed25519 signature provenance (file:// + shared OCI + target OCI)",
                "forged key-name and rotated-out signing key rejected and re-uploaded",
                "file:// bootstrap cache preserves upstream signatures",
                "restricted bundle exclusion and runtime reference truncation",
                "incremental and end-of-phase publication parity",
                "clean store multi-cache restore and zero duplicate upload on rerun",
                "authenticated cache read and interrupted NAR fallback without credential leakage",
            ],
        })
    )


if __name__ == "__main__":
    main()
