#!/usr/bin/env python3
"""Publish and restore a signed Nix closure through oranc and a local OCI registry."""

import base64
from contextlib import contextmanager
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
import tempfile

from tests.support import ROOT


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, **kwargs).stdout


def verify(uri, roots, public):
    run(["nix", "store", "verify", "--store", uri, "--recursive", "--sigs-needed", "1",
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
    fixture = '''let
      pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
      child = pkgs.writeText "public-cache-fixture-child" "synthetic content only";
    in pkgs.writeText "public-cache-fixture-root" "reference: ${child}"
    '''
    built = json.loads(run(["nix", "build", "--impure", "--no-link", "--json", "--expr", fixture], cwd=ROOT))
    roots = [built[0]["outputs"]["out"]]
    with tempfile.TemporaryDirectory(prefix="cache-integration-") as temporary:
        work = Path(temporary)
        # Each registry is empty; isolate Nix narinfo knowledge from earlier runs.
        os.environ["XDG_CACHE_HOME"] = str(work / "nix-client-cache")
        secret = work / "test.secret"
        secret.write_bytes(run(["nix", "key", "generate-secret", "--key-name", "synthetic-cache-test"]))
        secret.chmod(0o600)
        with secret.open("rb") as stream:
            public = run(["nix", "key", "convert-secret-to-public"], stdin=stream).decode().strip()
        exported = work / "cache"
        query = urllib.parse.urlencode({"secret-key": str(secret), "compression": "xz", "compression-level": 1})
        run(["nix", "copy", "--to", exported.as_uri() + "?" + query, *roots])
        verify(exported.as_uri(), roots, public)
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
            query = urllib.parse.urlencode({"endpoint": f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic"})
            environment = os.environ | {"AWS_ACCESS_KEY_ID": base64.b64encode(b"fixture:fixture").decode(),
                                       "AWS_SECRET_ACCESS_KEY": "_", "AWS_DEFAULT_REGION": "us-east-1",
                                       "AWS_EC2_METADATA_DISABLED": "true"}
            run(["nix", "copy", "--from", exported.as_uri(), "--to", "s3://cache-test?" + query, *roots], env=environment)
            uri = f"http://127.0.0.1:{proxy_port}/127.0.0.1:{registry_port}/synthetic/cache-test"
            verify(uri, roots, public)
            restored = work / "restored"
            run(["nix", "copy", "--from", uri, "--to", restored.as_uri(), *roots])
            verify(restored.as_uri(), roots, public)
            paths = json.loads(run(["nix", "path-info", "--store", restored.as_uri(),
                                         "--recursive", "--json", *roots]))
            assert len(paths) == 2, "root and referenced child must both be restored"
    print(json.dumps({"result": "passed", "scenarios": ["signed closure export", "OCI publication", "signature and content verification", "closure restore"]}))


if __name__ == "__main__":
    main()
