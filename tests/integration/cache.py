#!/usr/bin/env python3
"""Publish project outputs and restore a closure shared with a public Nix cache."""

from contextlib import contextmanager
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
import tempfile
from unittest.mock import patch
from urllib.request import urlopen

from tests.support import ROOT
from tests.support import load_source

cache = load_source(".github/ci/cache.py")
build = load_source(".github/ci/build.py")
report = load_source(".github/ci/report.py")
publish, select_paths = cache.publish, cache.select_paths
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
        yield
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def main():
    with tempfile.TemporaryDirectory(prefix="cache-integration-") as temporary:
        work = Path(temporary)
        # Unique names make deletion below specific to this invocation's output.
        fixture = '''let
          pkgs = (builtins.getFlake ("git+file://" + toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
          prefix = PREFIX;
          child = pkgs.writeText "${prefix}-child" "synthetic project content";
          publicLocal = pkgs.writeText "${prefix}-public-local" "known public signature";
          publicRemote = pkgs.writeText "${prefix}-public-remote" "remote public signature";
          buildInput = builtins.toFile "${prefix}-build-input" "build input";
          runtimeInput = builtins.toFile "${prefix}-runtime-input" "runtime input";
          source = pkgs.writeText "${prefix}-source" "synthetic restricted content";
          restricted = pkgs.runCommand "${prefix}-restricted" {} "cp ${source} $out";
          bundle = pkgs.runCommand "${prefix}-bundle" {} "cp ${restricted} $out";
          driver = pkgs.writeText "${prefix}-driver" "ready";
          failure = pkgs.runCommand "${prefix}-failed" {} "exit 17";
          root = pkgs.runCommand "${prefix}-result" {} ''
            test "$(cat ${driver})" = ready
            test "$(cat ${buildInput})" = 'build input'
            printf '%s' '${child}; ${publicLocal}; ${publicRemote}; ${runtimeInput}; prepared: ${bundle}' > $out
          '';
        in builtins.mapAttrs (_: value: { path = value.outPath; drv = value.drvPath; })
          { inherit child publicLocal publicRemote source restricted bundle driver root failure; }
          // { buildInput.path = buildInput; runtimeInput.path = runtimeInput; }
        '''.replace("PREFIX", json.dumps(work.name))
        fixture = json.loads(run(["nix", "eval", "--impure", "--json", "--expr", fixture], cwd=ROOT))

        def entry(name, **kwargs):
            return {"name": name, "drv": fixture[name]["drv"], "outputs": [fixture[name]["path"]], **kwargs}

        state = work / "metrics"
        test = entry("root", vm=True)
        dependency_names = ("bundle", "driver", "child", "publicLocal", "publicRemote")
        dependencies = [entry(name) for name in dependency_names]
        # A failed peer build must leave successfully realized dependencies
        # available for the first cache checkpoint.
        try:
            run_build([*dependencies, entry("failure")], state=state, phase="dependencies")
        except RuntimeError:
            assert valid_paths([fixture[name]["path"] for name in dependency_names]) == {
                fixture[name]["path"] for name in dependency_names}
        else:
            raise AssertionError("synthetic failing build unexpectedly succeeded")
        assert valid_paths([fixture["root"]["path"]]) == set(), "preparation must leave execution for the test stage"
        policy = {"roots": [fixture["root"]["drv"]],
                  "excludedPaths": [fixture[name]["path"] for name in ("source", "restricted")],
                  "excludedDerivations": [fixture["restricted"]["drv"]],
                  "bundles": [fixture["bundle"]["drv"]],
                  "builds": {"dependencies": dependencies, "vm-fixture": [test]}}
        (state / "policy.json").write_text(json.dumps(policy))
        roots = [fixture[name]["path"] for name in ("root", "child")]
        public_roots = [fixture[name]["path"] for name in ("publicLocal", "publicRemote")]

        def checkpoint(phase):
            selected, excluded = select_paths(policy)
            assert {fixture[name]["path"] for name in ("source", "restricted", "bundle")} <= set(excluded)
            # Send the selected synthetic products; upstream toolchain copies
            # add no coverage to this local registry exercise.
            paths = [path for path in selected if f"-{work.name}-" in path]
            expected_names = ["child", "driver", "publicLocal", "publicRemote"]
            if valid_paths([fixture["root"]["path"]]):
                expected_names += ["root", "runtimeInput"]
            assert set(paths) == {fixture[name]["path"] for name in expected_names}
            return publish(paths, f"127.0.0.1:{registry_port}", "synthetic/cache-test", state=state,
                           public_settings=public_settings, project_cache=uri, phase=phase, excluded_paths=excluded,
                           no_ssl=True, immutable=not os.access("/nix/var/nix/db", os.W_OK))
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
        public_settings = {"substituters": [public_uri], "trusted-public-keys": [upstream_public]}
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
        with listening(["registry", "serve", str(configuration)], registry_port), \
             listening(["oranc", "server", "--no-ssl", "--listen", f"127.0.0.1:{proxy_port}"], proxy_port):
            run(["oranc", "push", "--registry", f"127.0.0.1:{registry_port}",
                 "--repository", "synthetic/cache-test", "--no-ssl", "initialize", "--priority", "41"])
            uri = f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/cache-test"
            with urlopen(uri + "/nix-cache-info", timeout=10) as response:
                assert b"StoreDir: /nix/store" in response.read()
            os.environ["ORANC_SIGNING_KEY"] = secret.read_text().strip()
            first = checkpoint("dependencies")
            assert set(first) == {fixture[name]["path"] for name in ("child", "driver")}
            verify(uri, first, public)
            run_build([test], state=state, phase="vm-fixture")
            run_build([test], state=state, phase="vm-fixture", pass_name="committed")
            targets = [event for event in read_records(state / "timings.jsonl") if event.get("vm")]
            assert targets[0]["source"] == "built" and targets[0]["success"] and targets[0]["buildSeconds"] > 0
            assert targets[1]["source"] == "local" and targets[1]["success"] and targets[1]["buildSeconds"] is None
            assert set(checkpoint("results")) == {fixture[name]["path"] for name in ("root", "runtimeInput")}
            # A new run has no receipts. The project cache now supplies the
            # signatures for paths that earlier queries found absent.
            (state / "published-paths.json").unlink()
            assert checkpoint("remote-reuse") == []
            publications = [event for event in read_records(state / "timings.jsonl") if event["kind"] == "publication"]
            assert all(event["public"] == 2 for event in publications)
            assert publications[-1]["project"] == 4
            del os.environ["ORANC_SIGNING_KEY"]
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
        print(render(state))
    print(json.dumps({"result": "passed", "scenarios": ["redistribution selection including embedded payloads",
          "realized outputs and runtime references", "partial build publication and incremental checkpoints",
          "local public signatures and remote public/project deduplication", "signature and content verification",
          "persistent native Nix client configuration", "multi-cache restore with prepared private dependency",
          "dependency preparation, fresh execution, local reuse and cache restore timing"]}))


if __name__ == "__main__":
    main()
