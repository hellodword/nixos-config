#!/usr/bin/env python3
"""Prune unreferenced VPS release credentials and certificate state directories."""
import argparse
from pathlib import Path
import re
import shutil
import time

RELEASE_PATTERN = re.compile(r"/var/lib/site-vps/releases/([A-Za-z0-9._-]+)")
CERT_PATTERN = re.compile(r"/var/lib/site-vps-certificate/([A-Za-z0-9._-]+)")


def system_roots(profiles_dir=Path("/nix/var/nix/profiles"), runtime_dir=Path("/run")):
    roots = [
        runtime_dir / "current-system",
        runtime_dir / "booted-system",
        profiles_dir / "system",
    ]
    if profiles_dir.is_dir():
        roots.extend(sorted(profiles_dir.glob("system-*-link")))
    return roots


def referenced_ids(roots):
    releases, certs = set(), set()
    seen_targets = set()
    for candidate in roots:
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if resolved in seen_targets:
            continue
        seen_targets.add(resolved)
        unit_dir = resolved / "etc/systemd/system"
        if not unit_dir.is_dir():
            continue
        for entry in unit_dir.iterdir():
            if entry.suffix != ".service":
                continue
            try:
                text = entry.read_text(errors="replace")
            except OSError:
                continue
            releases.update(RELEASE_PATTERN.findall(text))
            certs.update(CERT_PATTERN.findall(text))
    return releases, certs


def prune_directory(base, keep, *, grace_seconds=900, now=None):
    if not base.is_dir():
        return []
    now = time.time() if now is None else now
    removed = []
    for child in sorted(base.iterdir()):
        if child.name in keep:
            continue
        try:
            stat_info = child.lstat()
        except OSError:
            continue
        if grace_seconds > 0 and now - stat_info.st_mtime < grace_seconds:
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink(missing_ok=True)
        removed.append(child.name)
    return removed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases-dir", type=Path, default=Path("/var/lib/site-vps/releases"))
    parser.add_argument("--certificates-dir", type=Path, default=Path("/var/lib/site-vps-certificate"))
    parser.add_argument("--profiles-dir", type=Path, default=Path("/nix/var/nix/profiles"))
    parser.add_argument("--runtime-dir", type=Path, default=Path("/run"))
    parser.add_argument("--keep-release", action="append", default=[])
    parser.add_argument("--keep-certificate", action="append", default=[])
    parser.add_argument("--grace-seconds", type=int, default=900)
    args = parser.parse_args()
    releases, certs = referenced_ids(system_roots(args.profiles_dir, args.runtime_dir))
    releases.update(args.keep_release)
    certs.update(args.keep_certificate)
    prune_directory(args.releases_dir, releases, grace_seconds=args.grace_seconds)
    prune_directory(args.certificates_dir, certs, grace_seconds=args.grace_seconds)


if __name__ == "__main__":
    main()
