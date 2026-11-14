#!/usr/bin/env python3
"""Publish project outputs and restore a closure shared with a public Nix cache."""

import argparse
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import threading
from unittest.mock import patch
from urllib.request import urlopen

from tests.support import ROOT
from tests.support import load_source

cache = load_source(".github/ci/cache.py")
build = load_source(".github/ci/build.py")
report = load_source(".github/ci/report.py")
run_build, valid_paths = build.run_build, build.valid_paths
read_records, render = report.read_records, report.render


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, **kwargs).stdout


def verify(uri, roots, public):
    # Read newly uploaded metadata after the pre-publication cache misses.
    run(["nix", "store", "verify", "--store", uri, "--sigs-needed", "1",
         "--option", "narinfo-cache-negative-ttl", "0",
         "--option", "trusted-public-keys", public, "--option", "extra-trusted-public-keys", "", *roots])


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
        print((state / "publisher.log").read_text(), file=sys.stderr)
        raise
    finally:
        cache.stop_publisher(state)


def checkpoint(state, phase, *, finish=False):
    run([sys.executable, str(ROOT / ".github/ci/cache.py"), "checkpoint", "--state", str(state),
         "--phase", phase, *(["--finish"] if finish else [])])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nixpkgs-input", choices=["nixpkgs", "nixpkgs-remote"], default="nixpkgs")
    args = parser.parse_args()
    publication_settings = cache.load_cache_settings()
    with tempfile.TemporaryDirectory(prefix="cache-integration-") as temporary, \
         build_gate() as (gate_url, entered, release):
        work = Path(temporary)
        # Unique names make deletion below specific to this invocation's output.
        fixture = '''let
          pkgs = (builtins.getFlake ("git+file://" + toString ./.)).inputs.NIXPKGS_INPUT.legacyPackages.x86_64-linux;
          prefix = PREFIX;
          child = pkgs.writeText "${prefix}-child" "synthetic project content";
          large = pkgs.writeText "${prefix}-large" (builtins.concatStringsSep "" (builtins.genList (_: "data") 2048));
          late = pkgs.writeText "${prefix}-late" "new result after registry interruption";
          publicLocal = pkgs.writeText "${prefix}-public-local" "known public signature";
          publicRemote = pkgs.writeText "${prefix}-public-remote" "remote public signature";
          buildInput = builtins.toFile "${prefix}-build-input" "build input";
          runtimeInput = builtins.toFile "${prefix}-runtime-input" "runtime input";
          source = pkgs.writeText "${prefix}-source" "synthetic restricted content";
          restricted = pkgs.runCommand "${prefix}-restricted" {} "cp ${source} $out";
          bundle = pkgs.runCommand "${prefix}-bundle" {} "cp ${restricted} $out";
          driver = pkgs.runCommand "${prefix}-driver" {} ''
            test -s ${child}
            ${pkgs.curl}/bin/curl --fail --max-time 240 GATE_URL
            printf ready > $out
          '';
          failure = pkgs.runCommand "${prefix}-failed" {} "exit 17";
          root = pkgs.runCommand "${prefix}-result" {} ''
            test "$(cat ${driver})" = ready
            test "$(cat ${buildInput})" = 'build input'
            printf '%s' '${child}; ${large}; ${publicLocal}; ${publicRemote}; ${runtimeInput}; prepared: ${bundle}' > $out
          '';
        in builtins.mapAttrs (_: value: { path = value.outPath; drv = value.drvPath; })
          { inherit child large late publicLocal publicRemote source restricted bundle driver root failure; }
          // { buildInput.path = buildInput; runtimeInput.path = runtimeInput; }
        '''.replace("NIXPKGS_INPUT", args.nixpkgs_input).replace("PREFIX", json.dumps(work.name)).replace("GATE_URL", json.dumps(gate_url))
        fixture = json.loads(run(["nix", "eval", "--impure", "--json", "--expr", fixture], cwd=ROOT))

        def entry(name, **kwargs):
            return {"name": name, "drv": fixture[name]["drv"], "outputs": [fixture[name]["path"]], **kwargs}

        state = work / "metrics"
        test = entry("root", vm=True)
        dependency_names = ("bundle", "driver", "child", "large", "publicLocal", "publicRemote")
        dependencies = [entry(name) for name in dependency_names]
        policy = {"roots": [fixture[name]["drv"] for name in ("root", "late")],
                  "excludedPaths": [fixture[name]["path"] for name in ("source", "restricted")],
                  "excludedDerivations": [fixture["restricted"]["drv"]],
                  "bundles": [fixture["bundle"]["drv"]],
                  "builds": {"dependencies": dependencies, "vm-fixture": [test]}}
        state.mkdir()
        (state / "policy.json").write_text(json.dumps(policy))
        inventory = cache.prepare_inventory(policy)
        assert {fixture[name]["path"] for name in ("source", "restricted", "bundle")} <= set(inventory["excluded"])
        # Keep the temporary registry exercise focused on synthetic products.
        inventory["outputs"] = [path for path in inventory["outputs"] if f"-{work.name}-" in path]
        inventory["derivations"] = [Path(value["drv"]).name for value in fixture.values() if "drv" in value]
        roots = [fixture[name]["path"] for name in ("root", "child", "large")]
        public_roots = [fixture[name]["path"] for name in ("publicLocal", "publicRemote")]
        run(["nix", "build", "--no-link", *[fixture[name]["drv"] + "^out" for name in ("publicLocal", "publicRemote")]])
        # Each registry is empty; isolate Nix narinfo knowledge from earlier runs.
        os.environ["XDG_CACHE_HOME"] = str(work / "nix-client-cache")
        secret = work / "test.secret"
        secret.write_bytes(run(["nix", "key", "generate-secret", "--key-name", "synthetic-cache-test"]))
        secret.chmod(0o600)
        with secret.open("rb") as stream:
            public = run(["nix", "key", "convert-secret-to-public"], stdin=stream).decode().strip()
        upstream_secret = work / "upstream.secret"
        upstream_secret.write_bytes(run(["nix", "key", "generate-secret", "--key-name", "synthetic-upstream"]))
        upstream_secret.chmod(0o600)
        with upstream_secret.open("rb") as stream:
            upstream_public = run(["nix", "key", "convert-secret-to-public"], stdin=stream).decode().strip()
        public_uri = (work / "public-cache").as_uri()
        publication_settings["public_settings"] = {"substituters": [public_uri], "trusted-public-keys": [upstream_public]}
        run(["nix", "store", "sign", "--key-file", str(upstream_secret), fixture["publicLocal"]["path"]])
        # Signing the destination cache leaves publicRemote unsigned locally.
        run(["nix", "copy", "--to", public_uri + "?secret-key=" + str(upstream_secret), *public_roots])
        registry_port, proxy_port = free_port(), free_port()
        configuration = work / "registry.json"
        configuration.write_text(json.dumps({
            "version": 0.1,
            "log": {"level": "error"},
            "storage": {"filesystem": {"rootdirectory": str(work / "registry")}},
            "http": {"addr": f"127.0.0.1:{registry_port}"},
        }))
        with listening(["registry", "serve", str(configuration)], registry_port) as registry_process, \
             listening(["oranc", "server", "--no-ssl", "--listen", f"127.0.0.1:{proxy_port}"], proxy_port):
            run(["oranc", "push", "--registry", f"127.0.0.1:{registry_port}",
                 "--repository", "synthetic/cache-test", "--no-ssl", "initialize", "--priority", "41"])
            uri = f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/cache-test"
            publication_settings["project_cache"] = uri
            with urlopen(uri + "/nix-cache-info", timeout=10) as response:
                assert b"StoreDir: /nix/store" in response.read()
            publisher_settings = dict(public_key=public, registry=f"127.0.0.1:{registry_port}",
                                      repository="synthetic/cache-test", no_ssl=True, **publication_settings)
            with publishing(state, inventory, secret=secret, **publisher_settings):
                run_build([entry("large")], state=state, phase="preparation")
                with ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(run_build, [*dependencies, entry("failure")],
                                         state=state, phase="dependencies", jobs=1)
                    try:
                        assert entered.wait(180), "the dependent build did not reach its gate"
                        deadline = time.monotonic() + 120
                        receipt = state / "published-paths.json"
                        while not receipt.exists() or fixture["child"]["path"] not in json.loads(receipt.read_text()):
                            status = json.loads((state / "cache/status.json").read_text())
                            assert status["result"] == "running", status
                            assert time.monotonic() < deadline, "completed dependency was not published during the build"
                            time.sleep(0.2)
                        verify(uri, [fixture["child"]["path"]], public)
                        assert not future.done(), "publication must complete while the dependent build is still running"
                        assert fixture["large"]["path"] not in json.loads(receipt.read_text())
                    finally:
                        release.set()
                    # A failed peer leaves completed dependencies for the checkpoint.
                    try:
                        future.result()
                    except RuntimeError:
                        assert valid_paths([fixture[name]["path"] for name in dependency_names]) == {
                            fixture[name]["path"] for name in dependency_names}
                    else:
                        raise AssertionError("synthetic failing build unexpectedly succeeded")
                assert valid_paths([fixture["root"]["path"]]) == set()
                checkpoint(state, "dependencies")
                first = set(json.loads(receipt.read_text()))
                assert first == {fixture[name]["path"] for name in ("child", "large", "driver")}
                verify(uri, first, public)
                run_build([test], state=state, phase="vm-fixture")
                run_build([test], state=state, phase="vm-fixture", pass_name="committed")
                targets = [event for event in read_records(state / "timings.jsonl") if event.get("vm")]
                assert targets[0]["source"] == "built" and targets[0]["success"] and targets[0]["buildSeconds"] > 0
                assert targets[1]["source"] == "local" and targets[1]["success"] and targets[1]["buildSeconds"] is None
                checkpoint(state, "results", finish=True)
                assert set(json.loads(receipt.read_text())) - first == {
                    fixture[name]["path"] for name in ("root", "runtimeInput")}
                events = read_records(state / "timings.jsonl")
                publications = [event for event in events if event["kind"] == "publication"]
                assert sum(event["excluded"] for event in publications) == 3
                assert sum(event["public"] for event in publications) == 2
                assert any(event["kind"] == "cache-upload" and event["group"] == "large"
                           and event["phase"] == "dependencies" for event in events)
            # A fresh run discovers remote signatures without previous receipts.
            remote_state = work / "remote"
            with publishing(remote_state, inventory, secret=secret, **publisher_settings):
                checkpoint(remote_state, "remote-reuse")
                publications = [event for event in read_records(remote_state / "timings.jsonl")
                                if event["kind"] == "publication"]
                assert sum(event["public"] for event in publications) == 2
                assert sum(event["project"] for event in publications) == 5
                assert not (remote_state / "published-paths.json").exists()
            assert json.loads((remote_state / "cache/status.json").read_text())["result"] == "stopped"
            verify(uri, [*roots, fixture["runtimeInput"]["path"]], public)
            # Evaluation keeps source inputs live; remove the build outputs to
            # exercise restoration from both caches.
            restore_paths = [*roots, *public_roots]
            expected = {path: Path(path).read_bytes() for path in restore_paths}
            run(["nix-store", "--delete", *restore_paths])
            # The excluded bundle is already present, just as CI prepares it
            # before restoring a successful test result from the public cache.
            # Install the production client's persistent configuration against
            # this registry and signing identity, without changing the caller's
            # nix.conf. The installer and renderer are the ordinary entrypoints.
            client = work / "client"
            (client / "scripts").mkdir(parents=True)
            (client / "nix").mkdir()
            installer = client / "scripts/nix-cache.sh"
            shutil.copyfile(ROOT / "scripts/nix-cache.sh", installer)
            shutil.copyfile(ROOT / "nix/cache-config.nix", client / "nix/cache-config-base.nix")
            (client / "flake.nix").write_text(
                "{ nixConfig = builtins.fromJSON " + json.dumps(json.dumps({
                    "extra-substituters": [public_uri], "extra-trusted-public-keys": [upstream_public],
                })) + "; }\n"
            )
            (client / "nix/cache-identity.json").write_text(json.dumps({"repository": "synthetic/cache-test", "publicKey": public}))
            project = {"listenAddress": "127.0.0.1", "port": proxy_port, "publicKey": public,
                       "registry": f"127.0.0.1:{registry_port}", "repository": "synthetic/cache-test"}
            (client / "nix/cache-config.nix").write_text(
                "let caches = import ./cache-config-base.nix; in caches // {\n"
                f"  local = caches.withProject (builtins.fromJSON {json.dumps(json.dumps(project))});\n}}\n"
            )
            config_home = work / "config"
            nix_conf = config_home / "nix/nix.conf"
            nix_conf.parent.mkdir(parents=True)
            nix_conf.write_text("# Existing client settings\nconnect-timeout = 7\n")
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config_home), "NIX_USER_CONF_FILES": str(nix_conf)}):
                run(["bash", str(installer), "install"])
                run(["bash", str(installer), "install"])
                lines = nix_conf.read_text().splitlines()
                assert "# Existing client settings" in lines
                assert lines.count("include nixos-config-cache.conf") == 1
                settings = json.loads(run(["nix", "config", "show", "--json"]))
                assert settings["connect-timeout"]["value"] == 7
                assert uri in settings["substituters"]["value"]
                assert public_uri in settings["substituters"]["value"]
                assert public in settings["trusted-public-keys"]["value"]
                assert upstream_public in settings["trusted-public-keys"]["value"]
                assert settings["require-sigs"]["value"]
                run_build([test], state=state, phase="vm-fixture", pass_name="restored")
            restored = [event for event in read_records(state / "timings.jsonl") if event.get("vm")][-1]
            assert restored["source"] == "substituted" and restored["success"]
            assert restored["buildSeconds"] is None and restored["restoreSeconds"] > 0
            verify("auto", roots, public)
            verify("auto", public_roots, upstream_public)
            assert all(Path(path).read_bytes() == content for path, content in expected.items())
            # A registry interruption must reach the same checkpoint used by CI.
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
                    assert any(event["kind"] == "cache-upload" and event["returncode"] != 0
                               for event in read_records(failure_state / "timings.jsonl"))
                else:
                    raise AssertionError("publication succeeded with an unavailable registry")
        print(render(state))
    print(json.dumps({"result": "passed", "scenarios": ["production cache configuration loading",
          "redistribution selection including embedded payloads",
          "native post-build hook and concurrent publication", "deferred large output publication",
          "realized outputs and runtime references", "partial build publication and incremental checkpoints",
          "registry failure propagation and publisher shutdown",
          "local public signatures and remote public/project deduplication", "signature and content verification",
          "persistent native Nix client configuration", "multi-cache restore with prepared private dependency",
          "dependency preparation, fresh execution, local reuse and cache restore timing"]}))


if __name__ == "__main__":
    main()
