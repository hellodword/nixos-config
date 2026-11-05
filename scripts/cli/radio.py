"""Play the configured public streams with bounded reconnects."""
import argparse
import json
import re
import signal
import subprocess
import time
import urllib.parse
import urllib.request


def fetch(url):
    with urllib.request.urlopen(url, timeout=20) as response:
        return response.read().decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("station", choices=["coderadio", "suno-radio"])
    parser.add_argument("playlist", nargs="?", default="status")
    args = parser.parse_args()
    if args.station == "coderadio":
        url = "https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3"
    else:
        source = fetch("https://raw.githubusercontent.com/hellodword/suno-radio/master/README.md")
        match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", source)
        if not match:
            raise RuntimeError("The station has not published a stream address")
        url = match.group() + "/v1/playlist"
        if args.playlist == "status":
            print(json.dumps(json.loads(fetch(url)), ensure_ascii=False, indent=2))
            return
        url += "/" + urllib.parse.quote(args.playlist, safe="")
    for attempt in range(3):
        with subprocess.Popen(["ffplay", "-hide_banner", "-autoexit", "-nodisp", "-i", url]) as child:
            try:
                status = child.wait()
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
        if status == 0:
            return
        if attempt < 2:
            time.sleep(3)
    raise RuntimeError("The stream failed after three attempts")


if __name__ == "__main__":
    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
