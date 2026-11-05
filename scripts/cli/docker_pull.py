"""Refresh locally used remote images; optional argv filters the tag list."""
import json
import subprocess
import sys
import time


def main():
    ids = subprocess.check_output(["docker", "images", "--quiet"], text=True).split()
    tags = set()
    for start in range(0, len(ids), 100):
        images = json.loads(subprocess.check_output(["docker", "inspect", *ids[start:start + 100]], text=True))
        for image in images:
            for tag in image.get("RepoTags") or []:
                if image.get("RepoDigests") or tag.startswith("ghcr.io/"):
                    tags.add(tag)
    if sys.argv[1:]:
        result = subprocess.run(sys.argv[1:], input="".join(tag + "\n" for tag in sorted(tags)),
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
