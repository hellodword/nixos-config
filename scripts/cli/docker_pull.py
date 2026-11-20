"""Refresh locally used remote images; optional argv filters the tag list."""
import argparse
import json
import subprocess
import sys
import time


def main(argv=None):
    parser = argparse.ArgumentParser(prog="docker-pull-my-images", description=__doc__)
    parser.add_argument(
        "filter",
        nargs=argparse.REMAINDER,
        help="optional filter command receiving sorted image tags on stdin",
    )
    args = parser.parse_args(argv)
    filter_cmd = args.filter[1:] if args.filter[:1] == ["--"] else args.filter
    ids = subprocess.check_output(["docker", "images", "--quiet"], text=True).split()
    tags = set()
    for start in range(0, len(ids), 100):
        images = json.loads(subprocess.check_output(["docker", "inspect", *ids[start:start + 100]], text=True))
        for image in images:
            for tag in image.get("RepoTags") or []:
                if image.get("RepoDigests") or tag.startswith("ghcr.io/"):
                    tags.add(tag)
    if filter_cmd:
        result = subprocess.run(filter_cmd, input="".join(tag + "\n" for tag in sorted(tags)),
                                text=True, capture_output=True, check=True)
        tags = set(result.stdout.splitlines())
    failed = []
    for tag in sorted(tags):
        print(f"Pulling {tag}", flush=True)
        for attempt in range(3):
            if subprocess.run(["docker", "pull", tag]).returncode == 0:
                break
            if attempt < 2:
                time.sleep(2)
        else:
            failed.append(tag)
    if failed:
        print("Failed images: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
