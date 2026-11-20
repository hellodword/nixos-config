#!/usr/bin/env python3
"""Start an infrastructure process after confirming official Mullvad exclusion."""
import os
from pathlib import Path
import sys


def excluded(cgroups):
    for line in cgroups.splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        hierarchy, controllers, path = parts
        if "net_cls" in controllers.split(",") and path == "/mullvad-exclusions":
            return True
        if hierarchy == "0" and controllers == "" and (
            path == "/mullvad-exclusions" or path.endswith("/mullvad-exclusions")
        ):
            return True
    return False


def main():
    # Verify actual cgroup membership across both net_cls (v1) and unified (v2)
    # hierarchies before starting an excluded infrastructure process.
    if not excluded(Path("/proc/self/cgroup").read_text()) or len(sys.argv) < 2:
        raise SystemExit("process exclusion is unavailable; waiting for the exclusion cgroup")
    os.execv(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    main()
