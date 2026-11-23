#!/usr/bin/env python3
"""Evaluate independent CI jobs via nix-eval-jobs and assemble manifest.json."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

try:
    from .report import record, utc_now
except ImportError:
    from report import record, utc_now

SANITIZED_NIXPKGS_VARS = (
    "NIXPKGS_ALLOW_BROKEN",
    "NIXPKGS_ALLOW_INSECURE",
    "NIXPKGS_ALLOW_UNFREE",
    "NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM",
)


@contextmanager
def sanitized_nixpkgs_env(base_env=None):
    """Isolate --impure flake/manifest evaluation from ambient host nixpkgs user settings."""
    with tempfile.TemporaryDirectory(prefix="nix-ci-nixpkgs-cfg-") as cfg_dir:
        empty_cfg = Path(cfg_dir) / "config.nix"
        empty_cfg.write_text("{}\n", encoding="utf-8")
        env = dict(os.environ if base_env is None else base_env)
        for key in SANITIZED_NIXPKGS_VARS:
            env.pop(key, None)
        env["NIXPKGS_CONFIG"] = str(empty_cfg)
        yield env


def default_system():
    return "x86_64-linux"


def nix_string_literal(value):
    return json.dumps(value, ensure_ascii=False).replace("${", r"\${")


def manifest_expression(project_dir, manifest_rel, select_obj, system):
    resolved = Path(project_dir).resolve()
    scheme = "git+file://" if (resolved / ".git").exists() else "path:"
    project_str = nix_string_literal(str(resolved))
    scheme_str = nix_string_literal(scheme)
    manifest_str = nix_string_literal(str(manifest_rel))
    select_str = nix_string_literal(json.dumps(select_obj, ensure_ascii=False))
    system_str = nix_string_literal(system)
    return (
        f"(import ({project_str} + \"/\" + {manifest_str}) {{"
        f" flake = builtins.getFlake ({scheme_str} + {project_str});"
        f" system = {system_str};"
        f" select = builtins.fromJSON {select_str};"
        f" }})."
    )


def progress(state, started, completed, total):
    event = {
        "kind": "evaluation-progress",
        "time": utc_now(),
        "seconds": time.monotonic() - started,
        "completed": completed,
        "total": total,
    }
    samples = Path(state) / "resources.jsonl"
    if samples.exists():
        lines = samples.read_bytes().split(b"\n")[:-1]
        if lines:
            event["resources"] = json.loads(lines[-1])
    else:
        memory = {
            line.split()[0].rstrip(":"): int(line.split()[1]) * 1024
            for line in Path("/proc/meminfo").read_text().splitlines()
            if len(line.split()) == 3
        }
        event["memoryAvailable"] = memory["MemAvailable"]
    print(json.dumps(event), flush=True)


def evaluate_jobs(command, expected, state, cwd=None, env=None):
    """Evaluate derivations through nix-eval-jobs and fail on any attribute error or missing output."""
    state = Path(state)
    results, failures = {}, []
    started = time.monotonic()
    next_progress = started + 60
    state.mkdir(parents=True, exist_ok=True)
    with (state / "evaluation.jsonl").open("wb") as evidence, selectors.DefaultSelector() as selector:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            start_new_session=True,
            cwd=cwd,
            env=env,
        )
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""

        def consume(line):
            evidence.write(line + b"\n")
            evidence.flush()
            item = json.loads(line)
            name = item.get("attr")
            error = item.get("error")
            if (
                error
                or not item.get("drvPath")
                or not item.get("outputs")
                or not all(item["outputs"].values())
            ):
                failures.append(name or "unknown attribute")
            elif expected is not None and (name not in expected or name in results):
                raise RuntimeError(f"Unexpected or duplicate evaluation result: {name}")
            elif name in results:
                raise RuntimeError(f"Duplicate evaluation result: {name}")
            else:
                results[name] = item
            stats = item.get("stats", {})
            record(
                state,
                {
                    "kind": "evaluation",
                    "name": name,
                    "success": not error and name in results,
                    "seconds": stats.get("wallMs", 0) / 1000,
                    "stats": stats,
                },
            )
            print(
                f"Evaluated {name}: {'failed' if name not in results else 'success'} "
                f"({stats.get('wallMs', 0) / 1000:.1f}s)",
                flush=True,
            )

        try:
            while selector.get_map():
                for key, _ in selector.select(timeout=max(0, next_progress - time.monotonic())):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    pending += chunk
                    lines = pending.split(b"\n")
                    pending = lines.pop()
                    for line in lines:
                        if line.strip():
                            consume(line)
                if time.monotonic() >= next_progress:
                    progress(state, started, len(results), len(expected) if expected is not None else 0)
                    next_progress = time.monotonic() + 60
            if pending.strip():
                consume(pending)
            returncode = process.wait()
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
    missing = (set(expected) - results.keys()) if expected is not None else set()
    if returncode or failures or missing:
        raise RuntimeError(
            f"Inventory evaluation failed (exit {returncode}); "
            f"failed or missing: {', '.join(sorted(missing | set(failures)))}; "
            "see evaluation.jsonl"
        )
    return results


def evaluate_manifest(*, project_dir, manifest_rel="nix/ci.nix", select_obj=None, state, system=None):
    project_dir = Path(project_dir).resolve()
    state = Path(state).resolve()
    select_obj = select_obj or {}
    system = system or default_system()
    state.mkdir(parents=True, exist_ok=True)
    destination = state / "manifest.json"
    destination.unlink(missing_ok=True)

    expr = manifest_expression(project_dir, manifest_rel, select_obj, system)
    eval_flags = ["--no-update-lock-file", "--impure"]

    def query(attribute, eval_env, wrapper=None):
        full_expr = f"{wrapper} ({expr}{attribute})" if wrapper else (expr + attribute)
        return json.loads(
            subprocess.check_output(
                ["nix", "eval", "--json", *eval_flags, "--expr", full_expr],
                cwd=project_dir,
                env=eval_env,
            )
        )

    started, start = utc_now(), time.monotonic()
    status = 1
    try:
        with sanitized_nixpkgs_env() as eval_env:
            job_names = set(query("jobs", eval_env, wrapper="builtins.attrNames"))
            raw_groups = query("groups", eval_env)
            results = evaluate_jobs(
                [
                    "nix-eval-jobs",
                    "--workers",
                    "2",
                    "--max-memory-size",
                    "5120",
                    "--impure",
                    "--expr",
                    expr + "jobs",
                ],
                job_names,
                state,
                cwd=project_dir,
                env=eval_env,
            )
            cache_config = query("cache", eval_env)
            update_config = query("update", eval_env)

        private_builds = []
        if cache_config is not None:
            private_builds = list(cache_config.get("privateBuilds") or [])

        resolved_groups = []
        has_private_group = any(group["name"] == "private" for group in raw_groups)
        if private_builds and not has_private_group:
            resolved_groups.append({
                "name": "private",
                "required": True,
                "vm": None,
                "kvm": False,
                "maxJobs": 1,
                "entries": [
                    {
                        "name": item["name"],
                        "drv": item["drv"],
                        "outputs": item["outputs"],
                        "required": True,
                        "vm": False,
                    }
                    for item in private_builds
                ],
            })

        for group in raw_groups:
            group_name = group["name"]
            group_vm = group.get("vm")
            group_required = bool(group.get("required", True))
            entries = []
            if group_name == "private" and private_builds:
                entries.extend(
                    {
                        "name": item["name"],
                        "drv": item["drv"],
                        "outputs": item["outputs"],
                        "required": group_required,
                        "vm": False,
                    }
                    for item in private_builds
                )
            for job_ref in group.get("jobs", []):
                if isinstance(job_ref, dict):
                    entries.append({
                        "name": job_ref["name"],
                        "drv": job_ref["drv"],
                        "outputs": job_ref["outputs"],
                        "required": group_required,
                        "vm": bool(group_vm),
                    })
                else:
                    if job_ref not in results:
                        raise RuntimeError(
                            f"Group '{group_name}' references unknown job '{job_ref}'"
                        )
                    evaluated = results[job_ref]
                    entries.append({
                        "name": job_ref,
                        "drv": evaluated["drvPath"],
                        "outputs": list(evaluated["outputs"].values()),
                        "required": group_required,
                        "vm": bool(group_vm),
                    })
            resolved_groups.append({
                "name": group_name,
                "required": group_required,
                "vm": group_vm,
                "kvm": bool(group.get("kvm", False)),
                "maxJobs": group.get("maxJobs", 1),
                "entries": entries,
            })

        roots = sorted({
            entry["drv"]
            for group in resolved_groups
            for entry in group["entries"]
        })

        manifest_payload = {
            "projectDir": str(project_dir),
            "manifest": str(manifest_rel),
            "system": system,
            "select": select_obj,
            "groups": resolved_groups,
            "roots": roots,
            "cache": cache_config,
            "update": update_config,
        }
        temporary = destination.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(manifest_payload, indent=2) + "\n")
        temporary.replace(destination)
        status = 0
        print(f"Manifest written: {destination} ({len(results)} evaluated jobs)", flush=True)
        return manifest_payload
    finally:
        record(
            state,
            {
                "kind": "phase",
                "phase": "evaluate",
                "started": started,
                "seconds": time.monotonic() - start,
                "returncode": status,
            },
        )
