#!/usr/bin/env python3
"""Publish project outputs and restore a closure shared with a public Nix cache."""

import argparse
import base64
from contextlib import contextmanager, redirect_stderr
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
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
from urllib.request import Request, urlopen

from tests.support import ROOT
from tests.support import load_source

cache = load_source(".github/ci/cache.py")
build = load_source(".github/ci/build.py")
report = load_source(".github/ci/report.py")
evaluate = load_source(".github/ci/evaluate.py")
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


@contextmanager
def interrupted_download(origin):
    """Serve real cache metadata, then close each NAR response halfway through."""
    interruptions = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            headers = {"Authorization": self.headers["Authorization"]} if "Authorization" in self.headers else {}
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
                    content = content[:len(content) // 2]
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


def authenticated_recovery(work, entry, inventory, publisher_settings, secret, proxy_port, proxy_log):
    username, password = "synthetic", "synthetic-cache-token"
    credentials = {"ORANC_USERNAME": username, "ORANC_PASSWORD": password,
                   "ORANC_SIGNING_KEY": secret.read_text().strip()}
    htpasswd = work / "htpasswd"
    # Fixed bcrypt hash of the public synthetic password above.
    htpasswd.write_text("synthetic:$2y$05$.NdRFJroQ.3tRrXEUgXFgu9kRotvL5mnO58wyQmtOgaveSjL5z8Gq\n")
    port = free_port()
    registry = f"127.0.0.1:{port}"
    configuration = work / "authenticated-registry.json"
    configuration.write_text(json.dumps({
        "version": 0.1, "log": {"level": "error"},
        "storage": {"filesystem": {"rootdirectory": str(work / "authenticated-registry")}},
        "http": {"addr": registry},
        "auth": {"htpasswd": {"realm": "synthetic", "path": str(htpasswd)}},
    }))
    netrc = work / "netrc"
    netrc.write_text(f"machine 127.0.0.1\nlogin {username}\npassword {password}\n")
    netrc.chmod(0o600)
    origin = f"http://127.0.0.1:{proxy_port}/{registry}/synthetic/source"
    output = entry["outputs"][0]
    with listening(["registry", "serve", str(configuration)], port):
        run(["nix", "build", "--no-link", entry["drv"] + "^*"])
        content = Path(output).read_bytes()
        with patch.dict(os.environ, credentials):
            push = ["oranc", "push", "--registry", registry, "--repository", "synthetic/source", "--no-ssl"]
            run([*push, "initialize", "--priority", "41"])
            run([*push, "--no-closure"], input=(output + "\n").encode())
        run(["nix-store", "--delete", output])
        config = os.environ.get("NIX_CONFIG", "") + f"\nnetrc-file = {netrc}\n"
        config += f"trusted-public-keys = {publisher_settings['public_key']}\nextra-trusted-public-keys =\n"
        with patch.dict(os.environ, {"NIX_CONFIG": config}):
            # Native Nix reads netrc; oranc forwards the credentials to the registry.
            run(["nix", "copy", "--from", origin, output])
            assert Path(output).read_bytes() == content
            run(["nix-store", "--delete", output])
            state = work / "recovery"
            with interrupted_download(origin) as (uri, interruptions), \
                 publishing(state, inventory, secret=secret, **publisher_settings), \
                 patch.dict(os.environ, {"NIX_CONFIG": config + f"substituters = {uri}\nextra-substituters =\n"
                                        "fallback = true\ndownload-attempts = 1\n"}):
                run_build([entry], state=state, phase="dependencies")
                checkpoint(state, "recovery", finish=True)
                target = [event for event in read_records(state / "timings.jsonl") if event["kind"] == "target"][-1]
                assert interruptions and target["source"] == "built" and target["success"], {
                    "interruptedDownloads": interruptions, "target": target}
                assert target["restoreSeconds"] > 0 and target["buildSeconds"] > 0
                assert Path(output).read_bytes() == content
                assert output in json.loads((state / "published-paths.json").read_text())
                verify(publisher_settings["project_cache"], [output], publisher_settings["public_key"])
        # These are the diagnostics CI retains, using only synthetic credentials.
        logs = [proxy_log, state / "publisher.log", state / "timings.jsonl", *(state / "logs").rglob("*.log")]
        for path in logs:
            text = path.read_text()
            assert password not in text
            assert base64.b64encode(f"{username}:{password}".encode()).decode() not in text
    netrc.unlink()


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
          recovered = pkgs.runCommand "${prefix}-recovered" {} ''
            printf 'result rebuilt after an interrupted cache download' > $out
          '';
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
          failure = pkgs.runCommand "${prefix}-failed" {} ''
            mkdir -p $out
            printf 'synthetic builder stdout\\n'
            printf 'synthetic builder stderr\\n' >&2
            exit 17
          '';
          root = pkgs.runCommand "${prefix}-result" {} ''
            test "$(cat ${driver})" = ready
            test "$(cat ${buildInput})" = 'build input'
            printf '%s' '${child}; ${large}; ${publicLocal}; ${publicRemote}; ${runtimeInput}; prepared: ${bundle}' > $out
          '';
        in builtins.mapAttrs (_: value: { path = value.outPath; drv = value.drvPath; })
          { inherit child large late recovered publicLocal publicRemote source restricted bundle driver root failure; }
          // { buildInput.path = buildInput; runtimeInput.path = runtimeInput; }
        '''.replace("NIXPKGS_INPUT", args.nixpkgs_input).replace("PREFIX", json.dumps(work.name)).replace("GATE_URL", json.dumps(gate_url))
        fixture = json.loads(run(["nix", "eval", "--impure", "--json", "--expr", fixture], cwd=ROOT))
        evaluation_state = work / "evaluation"
        expression = '{ valid = import ' + fixture["child"]["drv"] + '; broken = throw "synthetic evaluation failure"; }'
        try:
            evaluate.evaluate_jobs(["nix-eval-jobs", "--workers", "1", "--max-memory-size", "512",
                                    "--impure", "--expr", expression], {"valid", "broken"}, evaluation_state)
        except RuntimeError as error:
            assert "exit 0" in str(error)
            rows = read_records(evaluation_state / "evaluation.jsonl")
            assert any(row.get("attr") == "broken" and row.get("error") for row in rows)
            assert any(row.get("attr") == "valid" and row.get("drvPath") for row in rows)
        else:
            raise AssertionError("an evaluation error was accepted as a successful inventory")

        def entry(name, **kwargs):
            return {"name": name, "drv": fixture[name]["drv"], "outputs": [fixture[name]["path"]], **kwargs}

        state = work / "metrics"
        test = entry("root", vm=True)
        dependency_names = ("bundle", "driver", "child", "large", "publicLocal", "publicRemote")
        dependencies = [entry(name) for name in dependency_names]
        policy = {"roots": [fixture[name]["drv"] for name in ("root", "late", "recovered")],
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
        proxy_log = work / "oranc.log"
        with patch.dict(os.environ, {"RUST_LOG": "oranc=info,oranc::registry=debug"}), \
             proxy_log.open("w") as log, \
             listening(["registry", "serve", str(configuration)], registry_port) as registry_process, \
             listening(["oranc", "server", "--no-ssl", "--listen", f"127.0.0.1:{proxy_port}"], proxy_port, log):
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
                annotations = io.StringIO()
                with ThreadPoolExecutor(max_workers=1) as pool, redirect_stderr(annotations):
                    future = pool.submit(run_build, [*dependencies, entry("failure")],
                                         state=state, phase="dependencies", jobs=2, github_actions=True)
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
                        while not (errors := [event for event in read_records(state / "timings.jsonl")
                                              if event["kind"] == "build-error"]):
                            assert time.monotonic() < deadline, "build failure was not reported while the peer was running"
                            time.sleep(0.1)
                        while "::error::" not in annotations.getvalue():
                            assert time.monotonic() < deadline, "Actions error annotation was not emitted"
                            time.sleep(0.1)
                        assert errors[0]["phase"] == "dependencies"
                        while True:
                            retained = (state / errors[0]["log"]).read_text()
                            if "synthetic builder stdout" in retained and "synthetic builder stderr" in retained:
                                break
                            assert time.monotonic() < deadline, "builder output was not retained while the peer was running"
                            time.sleep(0.1)
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
                report.verify_results(state, "candidate")
                run_build([test], state=state, phase="vm-fixture", pass_name="committed")
                targets = [event for event in read_records(state / "timings.jsonl") if event.get("vm")]
                assert targets[0]["source"] == "built" and targets[0]["success"] and targets[0]["buildSeconds"] > 0
                assert targets[1]["source"] == "local" and targets[1]["success"] and targets[1]["buildSeconds"] is None
                # A failed retry must supersede this round's earlier success.
                failed = entry("failure", vm=True) | {"name": test["name"]}
                try:
                    run_build([failed], state=state, phase="vm-fixture")
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("the retry should fail with the fixture's native build error")
                events = read_records(state / "timings.jsonl")
                failed_attempt = [event for event in events if event["kind"] == "build"][-1]
                assert failed_attempt["returncode"] != 0
                assert "synthetic builder stderr" in (state / failed_attempt["log"]).read_text()
                assert not any(event["kind"] == "vm-evidence" and event["attempt"] == failed_attempt["attempt"] for event in events)
                evidence = next(event for event in events if event["kind"] == "vm-evidence")
                assert evidence["files"] == 1
                assert (state / evidence["path"] / Path(test["outputs"][0]).name).read_bytes() == Path(test["outputs"][0]).read_bytes()
                try:
                    report.verify_results(state, "candidate")
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("a previous success hid the latest failed retry")
                run_build([test], state=state, phase="vm-fixture")
                report.verify_results(state, "candidate")
                # Changing the inventory also requires the corresponding build result.
                changed = policy | {"builds": {"vm-fixture": [entry("driver", vm=True) | {"name": test["name"]}]}}
                (state / "policy.json").write_text(json.dumps(changed))
                try:
                    report.verify_results(state, "candidate")
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("the verifier accepted a different derivation under the same name")
                (state / "policy.json").write_text(json.dumps(policy))
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
            (client / "nix/public-caches.nix").write_text(
                "builtins.fromJSON " + json.dumps(json.dumps({
                    "substituters": [public_uri], "trusted-public-keys": [upstream_public],
                })) + "\n"
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
            authenticated_recovery(work, entry("recovered"), inventory, publisher_settings,
                                   secret, proxy_port, proxy_log)
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
          "evaluation errors with zero process exit status", "manifest and VM result verification",
          "authenticated cache reads and interrupted NAR fallback with publication",
          "synthetic credentials absent from retained diagnostics",
          "dependency preparation, fresh execution, local reuse and cache restore timing"]}))


if __name__ == "__main__":
    main()
