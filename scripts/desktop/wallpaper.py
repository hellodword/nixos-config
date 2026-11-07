"""Bing image collection and native Sway/i3 wallpaper presentation."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import math
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
STATE = Path.home() / ".local/state/site-wallpaper"
INTERVAL = 60 * 60


@contextmanager
def locked(name):
    runtime = Path(os.environ["XDG_RUNTIME_DIR"]) / "site-wallpaper"
    runtime.mkdir(mode=0o700, exist_ok=True)
    with (runtime / name).open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield runtime


def write_state(name, text):
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=STATE, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
            temporary.replace(STATE / name)
        finally:
            temporary.unlink(missing_ok=True)


def fetch_state():
    path = STATE / "fetch.json"
    return json.loads(path.read_text()) if path.exists() else {}


def timestamp():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def schedule(systemctl):
    with locked("schedule.lock"):
        # ExecStopPost also runs during logout; the next login restores the deadline.
        active = subprocess.run([systemctl, "--user", "is-active", "--quiet",
                                 "site-sway.target", "site-i3.target"], timeout=10)
        if active.returncode:
            return
        previous = fetch_state().get("lastAttempt")
        due = datetime.fromisoformat(previous).timestamp() + INTERVAL if previous else 0
        # Calendar timers need a future event, including the single overdue catch-up.
        due = math.ceil(max(due, time.time() + 2))
        timer = f"site-wallpaper-fetch@{due}.timer"
        result = subprocess.run([systemctl, "--user", "list-units", "--all", "--output=json",
                                 "site-wallpaper-fetch@*.timer"],
                                check=True, capture_output=True, text=True, timeout=10)
        obsolete = [unit["unit"] for unit in json.loads(result.stdout) if unit["unit"] != timer]
        if obsolete:
            subprocess.run([systemctl, "--user", "--no-block", "stop", *obsolete], check=True, timeout=10)
        # Do not wait inside the service's stop job for a timer ordered before it.
        subprocess.run([systemctl, "--user", "--no-block", "start", timer], check=True, timeout=10)
        print(f"Next wallpaper check: {datetime.fromtimestamp(due, timezone.utc).isoformat()}", flush=True)


def collect(feed_url):
    LIBRARY.mkdir(parents=True, exist_ok=True)
    collected = []
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
                decoded.load()
            temporary.replace(target)
            collected.append(target)
            print(f"Collected Bing wallpaper {target.name}", flush=True)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return collected


def fetch(feed_url, swaymsg, feh):
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    with locked("fetch.lock"):
        state = fetch_state() | {"lastAttempt": timestamp(), "result": "running"}
        write_state("fetch.json", json.dumps(state) + "\n")
        try:
            collected = collect(feed_url)
        except SystemExit:
            state["result"] = "interrupted"
            write_state("fetch.json", json.dumps(state) + "\n")
            raise
        except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
            state["result"] = "failed"
            print(f"Bing collection: {error}", file=sys.stderr)
        else:
            state.update(lastSuccess=timestamp(), result="new" if collected else "unchanged")
        write_state("fetch.json", json.dumps(state) + "\n")
        if state["result"] == "new":
            present(False, swaymsg, feh, preferred=max(collected, key=lambda p: p.stem))


def present(rotate, swaymsg, feh, preferred=None):
    with locked("lock") as runtime:
        images = sorted(p for p in LIBRARY.glob("*") if p.is_file()
                        and p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".bmp"})
        if not images:
            print("Wallpaper library is empty", flush=True)
            return
        state = STATE / "current"
        if not state.exists() and (runtime / "current").exists():
            write_state("current", (runtime / "current").read_text())
        current = Path(state.read_text()) if state.exists() else None
        choices = [p for p in images if p != current] if rotate and len(images) > 1 else images
        random.shuffle(choices)
        first = preferred or (current if not rotate else None)
        if first in choices:
            choices.remove(first)
            choices.insert(0, first)
        selected = None
        for candidate in choices:
            try:
                with Image.open(candidate) as decoded:
                    decoded.load()
                selected = candidate
                break
            except (OSError, ValueError):
                print(f"Cannot decode wallpaper: {candidate}", file=sys.stderr)
        if selected is None:
            print("Wallpaper library has no readable images", flush=True)
            return
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
        write_state("current", str(selected))
        print(f"Wallpaper: {selected.name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["fetch", "apply", "rotate", "schedule"])
    parser.add_argument("--feed-url", default=FEED)
    parser.add_argument("--swaymsg", required=True)
    parser.add_argument("--feh", required=True)
    parser.add_argument("--systemctl", required=True)
    args = parser.parse_args()
    if args.action == "fetch":
        if urllib.parse.urlsplit(args.feed_url).scheme != "https":
            parser.error("the image feed must use HTTPS")
        fetch(args.feed_url, args.swaymsg, args.feh)
    elif args.action == "schedule":
        schedule(args.systemctl)
    else:
        present(args.action == "rotate", args.swaymsg, args.feh)


if __name__ == "__main__":
    main()
