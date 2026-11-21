#!/usr/bin/env python3
"""Unified CLI entrypoint for shared Nix CI workflows."""

import argparse
import sys


def build_parser():
    parser = argparse.ArgumentParser(
        prog="nix-ci",
        description="Evaluate manifests, build groups, publish signed caches, render reports, and manage flake updates.",
    )
    parser.add_argument(
        "subcommand",
        nargs="?",
        choices=["evaluate", "build", "cache", "report", "update"],
        help="CI workflow stage to run",
    )
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.subcommand is None:
        parser.print_help()
        return 0
    print(f"nix-ci subcommand '{args.subcommand}' is registered.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
