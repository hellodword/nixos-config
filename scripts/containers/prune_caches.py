"""Prune shared devcontainer caches inside an isolated, networkless container."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

DEFAULT_IMAGE = "ghcr.io/hellodword/devcontainers-dev:agent"
SUBDIRS = (
    ("nix", 0o755),
    ("xdg", 0o700),
    ("cargo", 0o700),
)


def reject_symlink(path: Path) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError(f"refusing symlinked cache directory: {path}")
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError(f"cache path is not a directory: {path}")


def prepare_cache_dirs(cache_root: Path) -> None:
    reject_symlink(cache_root)
    cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    reject_symlink(cache_root)
    for name, mode in SUBDIRS:
        sub = cache_root / name
        reject_symlink(sub)
        if not sub.exists():
            sub.mkdir(mode=mode)
        reject_symlink(sub)


def image_exists(image: str) -> bool:
    result = subprocess.run(
        ["docker", "image", "inspect", "--format", "{{.Id}}", image],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def candidate_roots(cache_root: Path, persist_root: str | None) -> set[str]:
    roots = {
        os.path.normpath(str(cache_root)),
        os.path.normpath(os.path.realpath(cache_root)),
    }
    if persist_root:
        prefix = persist_root.rstrip("/")
        if prefix:
            for item in list(roots):
                if item.startswith("/") and not item.startswith(prefix + "/"):
                    roots.add(os.path.normpath(prefix + item))
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
    if not image_exists(args.image):
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

    prepare_cache_dirs(cache_root)
    roots = candidate_roots(cache_root, args.persist_root)
    mode_args: list[str] = []
    if "--idle" not in passthrough and not caches_in_use(roots):
        mode_args.append("--idle")

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
        "-v",
        f"{cache_root / 'nix'}:/var/cache/devcontainer-nix",
        "-v",
        f"{cache_root / 'xdg'}:/home/vscode/.cache",
        "-v",
        f"{cache_root / 'cargo'}:/home/vscode/.local/share/cargo",
        args.image,
        "devcontainer-runtime",
        "prune-caches",
        "--nix-cache-dir",
        "/var/cache/devcontainer-nix",
        "--xdg-cache-dir",
        "/home/vscode/.cache",
        "--cargo-home",
        "/home/vscode/.local/share/cargo",
        *mode_args,
        *passthrough,
    ]
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        print(f"devcontainer-cache-prune: {exc}", file=sys.stderr)
        raise SystemExit(1)
