"""Bing image collection and native Sway/i3 wallpaper presentation."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import random
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from PIL import Image

FEED = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-WW"
LIBRARY = Path.home() / "Pictures/wallpaper"


def fetch(feed_url):
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    LIBRARY.mkdir(parents=True, exist_ok=True)
    try:
        with urllib.request.urlopen(feed_url, timeout=15) as response:
            images = json.loads(response.read(1024 * 1024))["images"]
        for image in images:
            date = image["fullstartdate"]
            if not re.fullmatch(r"\d{12,14}", date):
                raise ValueError("Bing returned an invalid image date")
            target = LIBRARY / (date + ".jpg")
            if target.exists():
                continue
            url = urllib.parse.urljoin(feed_url, image["url"])
            if urllib.parse.urlsplit(url).scheme != "https":
                raise ValueError("wallpaper downloads require HTTPS")
            temporary = None
            try:
                deadline = time.monotonic() + 30
                with urllib.request.urlopen(url, timeout=15) as response, tempfile.NamedTemporaryFile(
                    dir=LIBRARY, prefix=".bing-", suffix=".part", delete=False
                ) as output:
                    temporary = Path(output.name)
                    size = 0
                    while chunk := response.read(64 * 1024):
                        size += len(chunk)
                        if size > 32 * 1024 * 1024 or time.monotonic() > deadline:
                            raise ValueError("wallpaper download exceeded its size or time limit")
                        output.write(chunk)
                with Image.open(temporary) as decoded:
                    decoded.verify()
                temporary.replace(target)
                print(f"Collected Bing wallpaper {target.name}", flush=True)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        # Collection is independent of presentation; a failed fetch is retried
        # by the next timer while the existing library remains usable.
        print(f"Bing collection: {error}", file=sys.stderr)


def present(rotate, swaymsg, feh):
    runtime = Path(os.environ["XDG_RUNTIME_DIR"]) / "site-wallpaper"
    runtime.mkdir(mode=0o700, exist_ok=True)
    with (runtime / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        images = sorted(p for p in LIBRARY.glob("*") if p.is_file()
                        and p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".bmp"})
        if not images:
            print("Wallpaper library is empty", flush=True)
            return
        state = runtime / "current"
        current = Path(state.read_text()) if state.exists() else None
        choices = [p for p in images if p != current] if rotate and len(images) > 1 else images
        selected = current if not rotate and current in images else random.choice(choices)
        session = os.environ.get("XDG_CURRENT_DESKTOP", "").split(":")
        if "sway" in session:
            command = [swaymsg, "output * bg " + json.dumps(str(selected), ensure_ascii=False) + " fill"]
            result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=15)
            if not all(item.get("success") for item in json.loads(result.stdout)):
                raise RuntimeError("Sway did not apply the wallpaper")
        elif "i3" in session:
            subprocess.run([feh, "--no-fehbg", "--bg-fill", str(selected)], check=True, timeout=15)
        else:
            return
        temporary = state.with_suffix(".new")
        temporary.write_text(str(selected))
        temporary.replace(state)
        print(f"Wallpaper: {selected.name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["fetch", "apply", "rotate"])
    parser.add_argument("--feed-url", default=FEED)
    parser.add_argument("--swaymsg", required=True)
    parser.add_argument("--feh", required=True)
    args = parser.parse_args()
    if args.action == "fetch":
        if urllib.parse.urlsplit(args.feed_url).scheme != "https":
            parser.error("the image feed must use HTTPS")
        fetch(args.feed_url)
    else:
        present(args.action == "rotate", args.swaymsg, args.feh)


if __name__ == "__main__":
    main()
