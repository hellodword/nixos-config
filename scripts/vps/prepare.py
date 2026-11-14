#!/usr/bin/env python3
"""Read decrypted VPS YAML from stdin and prepare deployment files in tmp/vps."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

import yaml

from model import Inventory
from clients import mobile, shadowrocket

ROOT = Path(__file__).resolve().parents[2]


def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n" if not isinstance(value, str) else value)
    path.chmod(0o600)


def generate(vps, directory):
    metadata = vps.metadata()
    write(directory / "metadata.json", metadata)
    for node in vps.nodes:
        release = metadata["nodes"][node]["release"]
        for name, value in {"proxy.json": vps.server(node), "certificate.json": vps.certificate_request(node)}.items():
            write(directory / "nodes" / node / release / name, value)
    subscription_worker = directory / "workers/subscriptions"
    certificate = directory / "workers/certificates"
    for name, location in (("subscriptions", subscription_worker), ("certificates", certificate)):
        location.mkdir(parents=True, mode=0o700)
        write(location / "index.js", (ROOT / "workers" / name / "index.js").read_text())
        write(location / "auth.js", (ROOT / "workers/auth.js").read_text())
        (location / ".wrangler").mkdir(mode=0o700)
        settings = vps.data["workers"][name]
        config = {"name": settings["name"], "main": "index.js", "compatibility_date": "2026-10-01",
                  "workers_dev": False, "preview_urls": False,
                  "observability": {"enabled": False}}
        if name == "subscriptions":
            config["assets"] = {"directory": "assets", "binding": "ASSETS", "run_worker_first": True,
                                "html_handling": "none", "not_found_handling": "none"}
        write(location / "wrangler.json", config)
    for subscription_id, subscription in vps.subscriptions.items():
        provider = vps.provider(subscription_id)
        for name, value in {"linux.json": provider, "sing-box.json": mobile(provider),
                            "shadowrocket.conf": shadowrocket(provider)}.items():
            write(subscription_worker / "assets" / subscription["path"][1:] / name, value)
            write(directory / "subscriptions" / subscription_id / name, value)
    # Credential bindings are uploaded using Wrangler's native secret command.
    cert_settings = vps.data["workers"]["certificates"]
    cert_auth = {node: [vps.secrets[vps.nodes[node]["certificateToken"]]] for node in vps.nodes}
    write(certificate / "secrets.json", {
        "ACCESS": json.dumps(cert_auth), "PORKBUN_DOMAIN": cert_settings["domain"],
        "PORKBUN_API_KEY": vps.secrets[cert_settings["apiKey"]],
        "PORKBUN_SECRET_KEY": vps.secrets[cert_settings["secretKey"]],
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    os.umask(0o077)
    output = Path.cwd() / "tmp/vps"
    if output.exists() or output.is_symlink():
        parser.error(f"{output} already exists; remove the previous deployment files before preparing again")
    try:
        inventory = Inventory(yaml.safe_load(sys.stdin))
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".vps-", dir=output.parent) as temp:
            directory = Path(temp)
            generate(inventory, directory)
            directory.rename(output)
    except (ValueError, KeyError, TypeError, yaml.YAMLError):
        parser.error("invalid VPS declaration; check the structure and secret references against data/secrets/vps.example.yaml")
    except OSError as error:
        print(f"Could not prepare deployment files: {error}", file=sys.stderr)
        return 1
    print(output)
    print("Remove tmp/vps after all deployments are complete. Wrangler login state is stored separately.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
