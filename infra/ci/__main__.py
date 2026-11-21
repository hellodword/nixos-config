#!/usr/bin/env python3
"""Unified CLI entrypoint for shared Nix CI workflows (evaluate / build / cache / report / update)."""

import argparse
import json
from pathlib import Path
import sys

# Allow execution both as `python3 -m infra.ci` and `python3 /path/to/infra/ci`.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from build import build_group
    from evaluate import evaluate_manifest
    from report import cgroup_path, monitor, render, resource_sample, run_phase, verify_results
    from update import merge as update_merge, prepare as update_prepare
else:
    from .build import build_group
    from .evaluate import evaluate_manifest
    from .report import cgroup_path, monitor, render, resource_sample, run_phase, verify_results
    from .update import merge as update_merge, prepare as update_prepare


def add_common_arguments(parser, *, state_required=True, include_default=True):
    default_or_suppress = (lambda val: val) if include_default else (lambda _: argparse.SUPPRESS)
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=default_or_suppress(Path(".")),
        help="Consumer repository directory (default: current directory)",
    )
    parser.add_argument(
        "--manifest",
        default=default_or_suppress("nix/ci.nix"),
        help="Relative path to the CI manifest inside --project-dir (default: nix/ci.nix)",
    )
    parser.add_argument(
        "--select",
        default=default_or_suppress("{}"),
        help="JSON selection object passed to the manifest (default: {})",
    )
    parser.add_argument(
        "--system",
        default=default_or_suppress(None),
        help="Nix system identifier (default: host platform)",
    )
    parser.add_argument(
        "--state",
        type=Path,
        required=state_required,
        default=argparse.SUPPRESS if not state_required else None,
        help="State and diagnostics directory",
    )


def parse_select(raw):
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(f"Invalid --select JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise SystemExit("--select must decode to a JSON object")
    return parsed


def build_parser():
    parser = argparse.ArgumentParser(
        prog="nix-ci",
        description="Evaluate manifests, build groups, publish signed caches, render reports, and manage flake updates.",
    )
    add_common_arguments(parser, state_required=False, include_default=True)
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # 1. evaluate
    eval_parser = subparsers.add_parser("evaluate", help="Evaluate manifest jobs and write manifest.json")
    add_common_arguments(eval_parser, state_required=False, include_default=False)

    # 2. build
    bld_parser = subparsers.add_parser("build", help="Build an evaluated execution group")
    add_common_arguments(bld_parser, state_required=False, include_default=False)
    bld_parser.add_argument("--group", required=True, help="Execution group name from manifest.json")
    bld_parser.add_argument("--pass-name", default="candidate", help="Verification pass label")
    bld_parser.add_argument("--jobs", type=int, help="Override Nix --max-jobs concurrency")
    bld_parser.add_argument("--github-actions", action="store_true", help="Emit ::error:: annotations")

    # 3. cache
    cache_parser = subparsers.add_parser("cache", help="Verify remote narinfo and publish signed cache paths")
    add_common_arguments(cache_parser, state_required=False, include_default=False)
    cache_parser.add_argument(
        "operation",
        choices=["start", "serve", "checkpoint", "stop", "publish"],
        help="Cache publication lifecycle operation",
    )
    cache_parser.add_argument("--phase", default="publication", help="Checkpoint or publication phase label")
    cache_parser.add_argument("--finish", action="store_true", help="Exit incremental publisher after checkpoint")
    cache_parser.add_argument("--no-ssl", action="store_true", help="Use plaintext HTTP when pushing to a local test registry")

    # 4. report
    report_parser = subparsers.add_parser("report", help="Sample resources, verify required targets, or render Markdown")
    add_common_arguments(report_parser, state_required=False, include_default=False)
    report_sub = report_parser.add_subparsers(dest="operation", required=True)

    for op in ("monitor", "sample", "verify", "summary"):
        op_parser = report_sub.add_parser(op)
        add_common_arguments(op_parser, state_required=False, include_default=False)
        if op in ("monitor", "sample"):
            op_parser.add_argument("--container-pid", type=int, default=None)
        if op == "verify":
            op_parser.add_argument("--pass-name", default="candidate")

    run_parser = report_sub.add_parser("run", help="Record wall time and exit status of a command")
    add_common_arguments(run_parser, state_required=False, include_default=False)
    run_parser.add_argument("--phase", required=True)
    run_parser.add_argument("command", nargs=argparse.REMAINDER)

    # 5. update
    update_parser = subparsers.add_parser("update", help="Prepare or merge verified flake lockfile updates")
    add_common_arguments(update_parser, state_required=False, include_default=False)
    update_parser.add_argument("operation", choices=["prepare", "merge"])

    return parser


def require_state(parser, args):
    state = getattr(args, "state", None)
    if state is None:
        parser.error("--state is required")
    return Path(state)


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    state = require_state(parser, args)
    select_obj = parse_select(args.select)

    if args.subcommand == "evaluate":
        evaluate_manifest(
            project_dir=args.project_dir,
            manifest_rel=args.manifest,
            select_obj=select_obj,
            state=state,
            system=args.system,
        )
        return 0

    if args.subcommand == "build":
        build_group(
            state=state,
            group_name=args.group,
            pass_name=args.pass_name,
            jobs=args.jobs,
            github_actions=args.github_actions,
        )
        return 0

    if args.subcommand == "cache":
        if __package__ in (None, ""):
            from cache import run_cache_command
        else:
            from .cache import run_cache_command
        run_cache_command(
            operation=args.operation,
            state=state,
            project_dir=args.project_dir,
            phase=args.phase,
            finish=args.finish,
            no_ssl=args.no_ssl,
        )
        return 0

    if args.subcommand == "report":
        if args.operation == "monitor":
            monitor(state, args.container_pid)
            return 0
        if args.operation == "sample":
            resource_sample(state, cgroup_path(args.container_pid))
            return 0
        if args.operation == "verify":
            verify_results(state, args.pass_name)
            return 0
        if args.operation == "summary":
            print(render(state), end="")
            return 0
        if args.operation == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                parser.error("report run requires a command after --")
            return run_phase(state, args.phase, command)

    if args.subcommand == "update":
        if args.operation == "prepare":
            update_prepare(
                project_dir=args.project_dir,
                manifest_rel=args.manifest,
                select_obj=select_obj,
                state=state,
                system=args.system,
            )
            return 0
        if args.operation == "merge":
            update_merge(project_dir=args.project_dir, state=state)
            return 0

    parser.error(f"Unsupported subcommand: {args.subcommand}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
