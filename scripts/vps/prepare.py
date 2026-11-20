#!/usr/bin/env python3
"""Read decrypted VPS YAML from stdin and prepare deployment files in tmp/vps."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

import yaml

from model import Inventory, DeclarationError, field, MODES, profile_name
from clients import mobile, shadowrocket, shadowrocket_nodes

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
        files = {"proxy.json": vps.server(node), "certificate.json": vps.certificate_request(node)}
        if (origin_prefix := vps.http_origin_prefix(node)) is not None:
            files["http-origin-prefix"] = origin_prefix + "\n"
        for name, value in files.items():
            write(directory / "nodes" / node / release / name, value)
    subscription_worker = directory / "workers/subscriptions"
    certificate = directory / "workers/certificates"
    for name, location in (("subscriptions", subscription_worker), ("certificates", certificate)):
        location.mkdir(parents=True, mode=0o700)
        write(location / "index.js", (ROOT / "workers" / name / "index.js").read_text())
        write(location / "auth.js", (ROOT / "workers/auth.js").read_text())
        (location / ".wrangler").mkdir(mode=0o700)
        settings = vps.worker(name)
        config = {"name": field(settings, "name", str, f"workers.{name}"), "main": "index.js", "compatibility_date": "2026-10-01",
                  "workers_dev": False, "preview_urls": False,
                  "observability": {"enabled": False}}
        if name == "subscriptions":
            config["assets"] = {"directory": "assets", "binding": "ASSETS", "run_worker_first": True,
                                "html_handling": "none", "not_found_handling": "none"}
        write(location / "wrangler.json", config)
    for subscription_id, subscription in vps.subscriptions.items():
        for mode in MODES:
            provider = vps.provider(subscription_id, mode)
            title = profile_name(subscription["name"], mode)
            folder = "" if mode == "hy2" else mode
            for name, value in {
                "linux.json": provider,
                "sing-box.json": mobile(provider, f"{subscription_id}/{mode}"),
                "shadowrocket.txt": shadowrocket_nodes(provider),
                "shadowrocket.conf": shadowrocket(provider),
                "shadowrocket-config.conf": shadowrocket(provider, title),
                "metadata.json": {"id": subscription_id, "name": title},
            }.items():
                write(subscription_worker / "assets" / subscription["path"][1:] / folder / name, value)
                write(directory / "subscriptions" / subscription_id / folder / name, value)
    # Credential bindings are uploaded using Wrangler's native secret command.
    cert_settings = vps.worker("certificates")
    cert_auth = {node: [vps.certificate_request(node)["token"]] for node in vps.nodes}
    write(certificate / "secrets.json", {
        "ACCESS": json.dumps(cert_auth), "PORKBUN_DOMAIN": field(cert_settings, "domain", str, "workers.certificates"),
        "PORKBUN_API_KEY": vps.secret(field(cert_settings, "apiKey", str, "workers.certificates"), "workers.certificates.apiKey"),
        "PORKBUN_SECRET_KEY": vps.secret(field(cert_settings, "secretKey", str, "workers.certificates"), "workers.certificates.secretKey"),
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
    except DeclarationError as error:
        parser.error(str(error))
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        location = f" at line {mark.line + 1}, column {mark.column + 1}" if mark else ""
        parser.error("invalid YAML syntax" + location)
    except (ValueError, KeyError, TypeError) as error:
        parser.error(f"could not render the VPS declaration ({type(error).__name__}); check native exit options")
    except OSError as error:
        print(f"Could not prepare deployment files: {error}", file=sys.stderr)
        return 1
    print(output)
    print("Remove tmp/vps after all deployments are complete. Wrangler login state is stored separately.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
