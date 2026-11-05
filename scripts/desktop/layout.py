#!/usr/bin/env python3
"""Restore a saved autorandr profile, or arrange unknown outputs using XRandR.

Private i3 service callback; no state files or hardware inventory are written.
XRandR chooses preferred modes (its native DPI fallback when none is marked).
"""

import argparse
import os
import re
import select
import subprocess
import sys
import time


def run(command, *, capture=False):
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        env={**os.environ, "LC_ALL": "C"},
    ).stdout


def arrange(autorandr, xrandr):
    # Profile matching, block hooks and application remain upstream behavior.
    if run([autorandr, "--detected"], capture=True).strip():
        run([autorandr, "--change"])
        return

    # The public fingerprint interface also respects autorandr's lid policy.
    # Retain only output names; do not persist or log EDIDs.
    fingerprint = run([autorandr, "--fingerprint"], capture=True)
    eligible = set()
    for line in fingerprint.splitlines():
        fields = line.split()
        if len(fields) != 2:
            raise ValueError("invalid autorandr fingerprint output")
        eligible.add(fields[0])
    if not eligible:
        return

    query = run([xrandr, "--query"], capture=True)
    headers = re.findall(r"^(\S+) (connected|disconnected)\b(.*)$", query, re.MULTILINE)
    outputs = {name: state for name, state, _ in headers}
    panning = {name for name, _, details in headers if " panning " in details}
    if not eligible <= {name for name, state in outputs.items() if state == "connected"}:
        raise ValueError("display topology changed during detection; layout left unchanged")

    # Internal panels first, then connector names. Saved profiles can specify
    # any other order, rotation, scaling or disabled output.
    ordered = sorted(eligible, key=lambda name: (not name.startswith(("eDP", "LVDS")), name))
    command = [xrandr]
    for name in sorted(outputs.keys() - eligible):
        command += ["--output", name, "--off"]
    for index, name in enumerate(ordered):
        command += [
            "--output", name, "--auto", "--preferred", "--rotate", "normal",
            "--reflect", "normal", "--transform", "none",
        ]
        # Some X servers reject RRSetPanning even for 0x0. Reset it only
        # when the current output actually reports an enabled panning area.
        if name in panning:
            command += ["--panning", "0x0"]
        if index == 0:
            command += ["--primary", "--pos", "0x0"]
        else:
            command += ["--right-of", ordered[index - 1]]
    run(command)


def watch(autorandr, xrandr):
    from Xlib import display
    from Xlib.ext import randr

    server = display.Display()
    try:
        server.screen().root.xrandr_select_input(randr.RROutputChangeNotifyMask)
        server.sync()
        output_event, output_subtype = server.extension_event.OutputChangeNotify
        previous = None
        deadline = time.monotonic()
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                topology = tuple(sorted(run([autorandr, "--fingerprint"], capture=True).splitlines()))
                if topology != previous:
                    arrange(autorandr, xrandr)
                    previous = topology
                deadline = None
            timeout = None if deadline is None else max(0, deadline - time.monotonic())
            if server.pending_events() or select.select([server.fileno()], [], [], timeout)[0]:
                while server.pending_events():
                    event = server.next_event()
                    if event.type == output_event and event.sub_code == output_subtype:
                        if event.connection != randr.Connected:
                            previous = None
                        # Apply the settled connector topology. Changes to a
                        # mode or rotation keep the user's current adjustment.
                        deadline = time.monotonic() + 0.3
    finally:
        server.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--autorandr", required=True, help="autorandr executable")
    parser.add_argument("--xrandr", required=True, help="XRandR executable")
    parser.add_argument("--watch", action="store_true", help="apply layouts when connected displays change")
    args = parser.parse_args()
    try:
        if args.watch:
            watch(args.autorandr, args.xrandr)
        else:
            arrange(args.autorandr, args.xrandr)
    except subprocess.CalledProcessError as error:
        print(f"display-layout: {error.cmd[0]} exited with status {error.returncode}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"display-layout: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
