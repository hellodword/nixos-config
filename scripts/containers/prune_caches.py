"""Prune shared devcontainer caches inside an isolated, networkless container."""

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

DEFAULT_IMAGE = "ghcr.io/hellodword/devcontainers-dev:latest"
CACHE_LAYOUT_LABEL = "devcontainers.nix.cache-layout"
MOUNT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
MODE_RE = re.compile(r"^0[0-7]{3}$")


def reject_symlink(path: Path) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError(f"refusing symlinked cache directory: {path}")
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError(f"cache path is not a directory: {path}")


def parse_cache_layout(raw_json: str, source: str) -> list[tuple[str, str, int]]:
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid cache layout JSON from {source}: {exc}") from exc

    if not isinstance(data, dict):
        raise TypeError(f"cache layout in {source} must be a JSON object")
    if data.get("version") != 1:
        raise RuntimeError(f"unsupported cache layout version in {source}")
    mounts = data.get("mounts")
    if not isinstance(mounts, list):
        raise TypeError(f"cache layout mounts in {source} must be a list")
    if not mounts:
        raise RuntimeError(f"empty cache layout mounts in {source}")

    seen_ids: set[str] = set()
    seen_targets: set[str] = set()
    parsed: list[tuple[str, str, int]] = []
    for entry in mounts:
        if not isinstance(entry, dict):
            raise TypeError(f"invalid cache mount entry in {source}")
        mount_id = entry.get("id")
        target = entry.get("target")
        mode_str = entry.get("mode")
        if not isinstance(mount_id, str):
            raise TypeError(f"cache mount id in {source} must be a string")
        if not MOUNT_ID_RE.match(mount_id):
            raise RuntimeError(f"invalid cache mount id in {source}: {mount_id!r}")
        if mount_id in seen_ids:
            raise RuntimeError(f"duplicate cache mount id in {source}: {mount_id!r}")
        if not isinstance(target, str):
            raise TypeError(f"cache mount target in {source} must be a string")
        if (
            not target.startswith(("/home/vscode/", "/var/cache/"))
            or ".." in Path(target).parts
        ):
            raise RuntimeError(f"invalid cache mount target in {source}: {target!r}")
        if target in seen_targets:
            raise RuntimeError(f"duplicate cache mount target in {source}: {target!r}")
        if not isinstance(mode_str, str):
            raise TypeError(f"cache mount mode in {source} must be a string")
        if not MODE_RE.match(mode_str):
            raise RuntimeError(f"invalid cache mount mode in {source}: {mode_str!r}")
        seen_ids.add(mount_id)
        seen_targets.add(target)
        parsed.append((mount_id, target, int(mode_str, 8)))
    return parsed


def inspect_image_layout(image: str) -> tuple[bool, str]:
    result = subprocess.run(
        [
            "docker",
            "image",
            "inspect",
            "--format",
            f'{{{{ index .Config.Labels "{CACHE_LAYOUT_LABEL}" }}}}',
            image,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return False, ""
    return True, result.stdout.strip()


def resolve_cache_mounts(
    *,
    label_json: str,
    explicit_layout: Path | None,
    cache_root: Path,
) -> list[tuple[str, str, int]]:
    if explicit_layout is not None:
        return parse_cache_layout(
            explicit_layout.read_text(encoding="utf-8"), str(explicit_layout)
        )
    if label_json:
        return parse_cache_layout(label_json, f"image label {CACHE_LAYOUT_LABEL}")
    fallback_file = cache_root.parent / "cache-layout.json"
    if fallback_file.is_file():
        return parse_cache_layout(
            fallback_file.read_text(encoding="utf-8"), str(fallback_file)
        )
    raise RuntimeError(
        f"image lacks {CACHE_LAYOUT_LABEL} label and {fallback_file} does not exist"
    )


def prepare_cache_dirs(cache_root: Path, mounts: list[tuple[str, str, int]]) -> None:
    reject_symlink(cache_root)
    cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_symlink(cache_root)
    for name, _, mode in mounts:
        sub = cache_root / name
        reject_symlink(sub)
        if not sub.exists():
            sub.mkdir(mode=mode)
        reject_symlink(sub)


def candidate_roots(cache_root: Path, persist_root: str | None) -> set[str]:
    roots = {
        os.path.normpath(str(cache_root)),
        os.path.normpath(os.path.realpath(cache_root)),
    }
    if persist_root:
        prefix = persist_root.rstrip("/")
        if prefix:
            roots |= {
                os.path.normpath(prefix + item)
                for item in roots
                if item.startswith("/") and not item.startswith(prefix + "/")
            }
    return roots


def caches_in_use(roots: set[str]) -> bool:
    ids = subprocess.check_output(["docker", "ps", "-q"], text=True).split()
    for start in range(0, len(ids), 100):
        containers = json.loads(
            subprocess.check_output(
                ["docker", "inspect", *ids[start : start + 100]],
                text=True,
            )
        )
        for container in containers:
            for mount in container.get("Mounts") or []:
                source = mount.get("Source")
                if not source:
                    continue
                normalized = os.path.normpath(source)
                if any(
                    normalized == root or normalized.startswith(root + "/")
                    for root in roots
                ):
                    return True
    return False


def default_cache_root() -> Path:
    state_home = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(state_home) / "devcontainers/cache"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="devcontainer-cache-prune",
        description=__doc__,
    )
    parser.add_argument("--cache-root", type=Path, default=None)
    parser.add_argument("--cache-layout", type=Path, default=None)
    parser.add_argument("--persist-root", default=None)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument(
        "--require-image",
        action="store_true",
        help="fail instead of skipping when the prune container image is not present locally",
    )
    args, passthrough = parser.parse_known_args(argv)
    if passthrough[:1] == ["--"]:
        passthrough = passthrough[1:]

    cache_root = (args.cache_root or default_cache_root()).expanduser()
    present, label_json = inspect_image_layout(args.image)
    if not present:
        if args.require_image:
            print(
                f"devcontainer-cache-prune: image not present locally: {args.image}",
                file=sys.stderr,
            )
            return 1
        print(
            f"devcontainer-cache-prune: skipping, image not present locally: {args.image}",
            flush=True,
        )
        return 0

    mounts = resolve_cache_mounts(
        label_json=label_json,
        explicit_layout=args.cache_layout,
        cache_root=cache_root,
    )
    prepare_cache_dirs(cache_root, mounts)
    roots = candidate_roots(cache_root, args.persist_root)
    mode_args: list[str] = []
    if "--idle" not in passthrough and not caches_in_use(roots):
        mode_args.append("--idle")

    volume_args: list[str] = []
    for mount_id, target, _ in mounts:
        volume_args.extend(["-v", f"{cache_root / mount_id}:{target}"])

    command = [
        "docker",
        "run",
        "--pull=never",
        "--rm",
        "--network",
        "none",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true",
        "--pids-limit=256",
        *volume_args,
        args.image,
        "devcontainer-runtime",
        "prune-caches",
        *mode_args,
        *passthrough,
    ]
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        TypeError,
        ValueError,
    ) as exc:
        print(f"devcontainer-cache-prune: {exc}", file=sys.stderr)
        raise SystemExit(1)
