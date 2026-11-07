"""Present the shared background through the session's native PAM locker."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def render_x11(image, xrandr):
    from PIL import Image, ImageOps

    query = subprocess.run([xrandr, "--query"], check=True, capture_output=True, text=True,
                           timeout=1, env={**os.environ, "LC_ALL": "C"}).stdout
    size = re.search(r"current (\d+) x (\d+)", query)
    if size is None:
        raise ValueError("X11 framebuffer size is unavailable")
    canvas = Image.new("RGB", tuple(map(int, size.groups())), "#171d35")
    outputs = re.findall(r"^\S+ connected(?: primary)? (\d+)x(\d+)([+-]\d+)([+-]\d+)", query, re.MULTILINE)
    if not outputs:
        raise ValueError("X11 has no active display geometry")
    with Image.open(image) as source:
        for width, height, x, y in outputs:
            fitted = ImageOps.fit(source, (int(width), int(height)), method=Image.Resampling.LANCZOS)
            canvas.paste(fitted, (int(x), int(y)))
    directory = Path(os.environ["XDG_RUNTIME_DIR"]) / "site-lock"
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / "i3.png"
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        output = Path(temporary) / "image.png"
        canvas.save(output, format="PNG")
        # The complete file is published together, even for simultaneous locks.
        output.replace(target)
    return str(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", choices=("sway", "i3", "render-x11"))
    parser.add_argument("--foreground", action="store_true")
    for name in ("image", "swaylock", "i3lock", "xrandr"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    if args.session == "render-x11":
        print(render_x11(args.image, args.xrandr))
        return 0
    if args.session == "sway":
        command = [args.swaylock, "--color", "171d35", "--scaling", "fill",
                   "--inside-color", "171d35dd", "--ring-color", "89b4fa",
                   "--inside-wrong-color", "171d35", "--ring-wrong-color", "f38ba8",
                   "--key-hl-color", "cdd6f4", "--text-color", "cdd6f4"]
        if Path(args.image).is_file():
            command += ["--image", args.image]
        if not args.foreground:
            command += ["--daemonize"]
    else:
        command = [args.i3lock, "--color", "171d35"]
        if args.foreground:
            command += ["--nofork"]
        try:
            # Leave time for native locking within logind's five-second delay.
            # The parent retains xss-lock's inhibitor FD throughout image work.
            rendered = subprocess.run([sys.executable, __file__, "render-x11",
                                       "--image", args.image, "--xrandr", args.xrandr,
                                       "--swaylock", args.swaylock, "--i3lock", args.i3lock],
                                      check=True, capture_output=True, text=True, timeout=2)
            command += ["--image", rendered.stdout.strip()]
        except (OSError, subprocess.SubprocessError) as error:
            print(f"desktop-lock: using solid background: {error}", file=sys.stderr)
    # exec preserves the sleep-lock descriptor inherited from xss-lock until
    # i3lock closes it after acquiring the keyboard/pointer grabs.
    os.execv(command[0], command)


if __name__ == "__main__":
    sys.exit(main())
