#!/usr/bin/env python3
"""Start an infrastructure process after confirming official Mullvad exclusion."""
import os
from pathlib import Path
import sys


def excluded(cgroups):
    return any("net_cls" in controllers.split(",") and path == "/mullvad-exclusions"
               for _, controllers, path in (line.split(":", 2) for line in cgroups.splitlines()))


def main():
    # The pinned nixpkgs Mullvad 2026.5 builds the net_cls implementation. Its
    # exclude helper returns success when no net_cls mount exists, so its exit
    # status alone does not prove exclusion. Do not silently run unexcluded.
    if not excluded(Path("/proc/self/cgroup").read_text()) or len(sys.argv) < 2:
        raise SystemExit("process exclusion is unavailable; waiting for the exclusion cgroup")
    os.execv(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
