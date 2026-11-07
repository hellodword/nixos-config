#!/usr/bin/env python3
"""Publish and restore a signed Nix closure through oranc and a local OCI registry."""

from contextlib import contextmanager
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
import tempfile

from tests.support import ROOT
from scripts.ci.cache import publish, select_paths


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, **kwargs).stdout


def verify(uri, roots, public):
    run(["nix", "store", "verify", "--store", uri, "--sigs-needed", "1",
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
          pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
          prefix = PREFIX;
          child = pkgs.writeText "${prefix}-child" "synthetic public content";
          source = pkgs.writeText "${prefix}-source" "synthetic restricted content";
          restricted = pkgs.runCommand "${prefix}-restricted" {} "cp ${source} $out";
          bundle = pkgs.runCommand "${prefix}-bundle" {} "cp ${restricted} $out";
          root = pkgs.writeText "${prefix}-result" "public: ${child}; prepared: ${bundle}";
        in builtins.mapAttrs (_: value: { path = value.outPath; drv = value.drvPath; })
          { inherit child source restricted bundle root; }
        '''.replace("PREFIX", json.dumps(work.name))
        fixture = json.loads(run(["nix", "eval", "--impure", "--json", "--expr", fixture], cwd=ROOT))
        run(["nix", "build", "--no-link", fixture["root"]["drv"] + "^*"])
        policy = {"roots": [fixture["root"]["drv"]],
                  "excludedPaths": [fixture[name]["path"] for name in ("source", "restricted")],
                  "excludedDerivations": [fixture["restricted"]["drv"]],
                  "bundles": [fixture["bundle"]["drv"]]}
        selected, excluded = select_paths(policy)
        roots = [fixture[name]["path"] for name in ("root", "child")]
        assert set(roots) <= set(selected)
        assert {fixture[name]["path"] for name in ("source", "restricted", "bundle")} <= set(excluded)
        expected = {path: Path(path).read_bytes() for path in roots}
        # Each registry is empty; isolate Nix narinfo knowledge from earlier runs.
        os.environ["XDG_CACHE_HOME"] = str(work / "nix-client-cache")
        secret = work / "test.secret"
        secret.write_bytes(run(["nix", "key", "generate-secret", "--key-name", "synthetic-cache-test"]))
        secret.chmod(0o600)
        with secret.open("rb") as stream:
            public = run(["nix", "key", "convert-secret-to-public"], stdin=stream).decode().strip()
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
            os.environ["ORANC_SIGNING_KEY"] = secret.read_text().strip()
            # The developer daemon owns its DB; no Nix writes occur during push.
            # CI's root-owned store uses the ordinary SQLite mode instead.
            publish(roots, f"127.0.0.1:{registry_port}", "synthetic/cache-test",
                    no_ssl=True, immutable=not os.access("/nix/var/nix/db", os.W_OK))
            del os.environ["ORANC_SIGNING_KEY"]
            uri = f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/cache-test"
            verify(uri, roots, public)
            run(["nix-store", "--delete", *roots])
            # The excluded bundle is already present, just as CI prepares it
            # before restoring a successful test result from the public cache.
            run(["nix-store", "--realise", fixture["root"]["path"],
                 "--option", "substituters", uri, "--option", "extra-substituters", "",
                 "--option", "trusted-public-keys", public, "--option", "extra-trusted-public-keys", "",
                 "--option", "require-sigs", "true"])
            verify("auto", roots, public)
            assert all(Path(path).read_bytes() == content for path, content in expected.items())
    print(json.dumps({"result": "passed", "scenarios": ["redistribution selection including embedded payloads",
          "direct signed OCI publication", "signature and content verification", "restore with prepared private dependency"]}))


if __name__ == "__main__":
    main()
