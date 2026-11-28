"""Forward local IPv4 TCP ports to running Docker containers via socat."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import ipaddress
import json
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

HELPER_IMAGE = "alpine/socat"


def parse_endpoint(raw: str, *, default_ip: str, label: str) -> tuple[str, int]:
    if ":" in raw:
        host_part, port_part = raw.rsplit(":", 1)
        try:
            ip = str(ipaddress.IPv4Address(host_part))
        except ipaddress.AddressValueError as exc:
            raise ValueError(f"invalid {label} IPv4 address in {raw!r}") from exc
    else:
        ip = default_ip
        port_part = raw

    if not port_part.isdigit():
        raise ValueError(f"invalid {label} port in {raw!r}")
    port = int(port_part, 10)
    if not (1 <= port <= 65535):
        raise ValueError(f"{label} port out of range in {raw!r}: {port}")
    return ip, port


def resolve_target(container: str) -> tuple[str, bool]:
    res = subprocess.run(
        ["docker", "container", "inspect", container],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        msg = res.stderr.strip() or f"failed to inspect container {container}"
        raise RuntimeError(msg)
    items = json.loads(res.stdout)
    if not items or not isinstance(items[0], dict):
        raise RuntimeError(f"container not found: {container}")
    info = items[0]
    if not (info.get("State") or {}).get("Running"):
        raise RuntimeError(f"container is not running: {container}")
    cid = info.get("Id")
    if not isinstance(cid, str) or not cid:
        raise RuntimeError(f"missing container ID for {container}")
    probe = subprocess.run(
        ["docker", "exec", cid, "socat", "-V"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return cid, probe.returncode == 0


async def _pump_to_proc(
    reader: asyncio.StreamReader, proc_stdin: asyncio.StreamWriter
) -> None:
    try:
        while data := await reader.read(65536):
            proc_stdin.write(data)
            await proc_stdin.drain()
    except OSError:
        pass
    finally:
        with contextlib.suppress(OSError):
            proc_stdin.close()


async def _pump_to_client(
    proc_stdout: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    try:
        while data := await proc_stdout.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        pass


async def serve_forwards(
    mappings: list[tuple[str, str, str, int, str, int]],
    has_socat: dict[str, bool],
) -> int:
    locks = {cid: asyncio.Lock() for cid in has_socat}
    helpers: dict[str, tuple[str, asyncio.subprocess.Process]] = {}
    active_tasks: set[asyncio.Task[None]] = set()
    servers: list[asyncio.Server] = []

    with tempfile.TemporaryDirectory(prefix="docker-port-forward-") as tmp_dir:

        async def exec_target_for(cid: str) -> str:
            if has_socat[cid]:
                return cid
            async with locks[cid]:
                existing = helpers.get(cid)
                if existing is not None and existing[1].returncode is None:
                    return existing[0]
                cid_file = Path(tmp_dir) / f"helper-{cid[:12]}-{secrets.token_hex(4)}.cid"
                proc = await asyncio.create_subprocess_exec(
                    "docker",
                    "run",
                    "--rm",
                    "-i",
                    "--cidfile",
                    str(cid_file),
                    "--cap-drop=ALL",
                    "--security-opt=no-new-privileges:true",
                    "--network",
                    f"container:{cid}",
                    "--entrypoint",
                    "/bin/sh",
                    HELPER_IMAGE,
                    "-c",
                    "echo READY; exec cat >/dev/null",
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                )
                assert proc.stdout is not None and proc.stdin is not None
                try:
                    line = await proc.stdout.readline()
                    if line.decode(errors="replace").strip() != "READY":
                        raise RuntimeError(
                            f"failed to start {HELPER_IMAGE} helper for container {cid[:12]}"
                        )
                    helper_cid = cid_file.read_text(encoding="utf-8").strip()
                except BaseException:
                    with contextlib.suppress(OSError):
                        proc.stdin.close()
                    if proc.returncode is None:
                        with contextlib.suppress(ProcessLookupError):
                            proc.terminate()
                    await proc.wait()
                    raise
                helpers[cid] = (helper_cid, proc)
                return helper_cid

        async def handle_connection(
            reader: asyncio.StreamReader,
            writer: asyncio.StreamWriter,
            cid: str,
            dst_ip: str,
            dst_port: int,
        ) -> None:
            proc: asyncio.subprocess.Process | None = None
            try:
                exec_cid = await exec_target_for(cid)
                proc = await asyncio.create_subprocess_exec(
                    "docker",
                    "exec",
                    "-i",
                    exec_cid,
                    "socat",
                    "-t",
                    "30",
                    "STDIO",
                    f"TCP4:{dst_ip}:{dst_port}",
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                )
                assert proc.stdin is not None and proc.stdout is not None
                in_task = asyncio.create_task(_pump_to_proc(reader, proc.stdin))
                try:
                    await _pump_to_client(proc.stdout, writer)
                    await proc.wait()
                finally:
                    in_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await in_task
            except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
                print(f"docker-port-forward: {exc}", file=sys.stderr)
            finally:
                if proc is not None and proc.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        proc.terminate()
                    await proc.wait()
                writer.close()
                with contextlib.suppress(OSError):
                    await writer.wait_closed()

        def make_handler(cid: str, dst_ip: str, dst_port: int):
            def _on_connect(
                reader: asyncio.StreamReader, writer: asyncio.StreamWriter
            ) -> None:
                task = asyncio.create_task(
                    handle_connection(reader, writer, cid, dst_ip, dst_port)
                )
                active_tasks.add(task)
                task.add_done_callback(active_tasks.discard)

            return _on_connect

        stop_event = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop_event.set)

        try:
            for name, cid, host_ip, host_port, dst_ip, dst_port in mappings:
                try:
                    srv = await asyncio.start_server(
                        make_handler(cid, dst_ip, dst_port),
                        host=host_ip,
                        port=host_port,
                        family=socket.AF_INET,
                    )
                except OSError as exc:
                    print(
                        f"docker-port-forward: failed to bind {host_ip}:{host_port}: {exc.strerror or exc}",
                        file=sys.stderr,
                    )
                    return 1
                servers.append(srv)

            for name, cid, host_ip, host_port, dst_ip, dst_port in mappings:
                print(
                    f"{host_ip}:{host_port} -> {name} ({cid[:12]}) {dst_ip}:{dst_port}",
                    flush=True,
                )

            await stop_event.wait()
            return 0
        finally:
            for srv in servers:
                srv.close()
            for srv in servers:
                with contextlib.suppress(OSError):
                    await srv.wait_closed()
            for task in list(active_tasks):
                task.cancel()
            if active_tasks:
                await asyncio.gather(*active_tasks, return_exceptions=True)
            for _, proc in helpers.values():
                if proc.stdin is not None:
                    with contextlib.suppress(OSError):
                        proc.stdin.close()
            for _, proc in helpers.values():
                with contextlib.suppress(OSError):
                    await asyncio.wait_for(proc.wait(), timeout=5.0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="docker-port-forward",
        description=__doc__,
    )
    parser.add_argument(
        "--forward",
        nargs=3,
        action="append",
        required=True,
        metavar=("CONTAINER", "HOST_ENDPOINT", "CONTAINER_ENDPOINT"),
        help="Forward HOST_ENDPOINT ([IPv4:]port, default 0.0.0.0) to CONTAINER_ENDPOINT ([IPv4:]port, default 127.0.0.1)",
    )
    args = parser.parse_args(argv)

    parsed_specs: list[tuple[str, str, int, str, int]] = []
    seen_listeners: set[tuple[str, int]] = set()
    for container, raw_host, raw_dst in args.forward:
        try:
            host_ip, host_port = parse_endpoint(
                raw_host, default_ip="0.0.0.0", label="host"
            )
            dst_ip, dst_port = parse_endpoint(
                raw_dst, default_ip="127.0.0.1", label="container"
            )
        except ValueError as exc:
            parser.error(str(exc))
        if (host_ip, host_port) in seen_listeners:
            parser.error(f"duplicate listener {host_ip}:{host_port}")
        seen_listeners.add((host_ip, host_port))
        parsed_specs.append((container, host_ip, host_port, dst_ip, dst_port))

    resolved: dict[str, tuple[str, bool]] = {}
    has_socat: dict[str, bool] = {}
    mappings: list[tuple[str, str, str, int, str, int]] = []
    try:
        for container, host_ip, host_port, dst_ip, dst_port in parsed_specs:
            if container not in resolved:
                cid, socat_ok = resolve_target(container)
                resolved[container] = (cid, socat_ok)
                has_socat[cid] = socat_ok
            cid, _ = resolved[container]
            mappings.append((container, cid, host_ip, host_port, dst_ip, dst_port))
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        print(f"docker-port-forward: {exc}", file=sys.stderr)
        return 1

    return asyncio.run(serve_forwards(mappings, has_socat))


if __name__ == "__main__":
    raise SystemExit(main())
