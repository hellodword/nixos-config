"""Production resolver stack, queries and dnstap observations for process scenarios."""
import base64
import contextlib
import grp
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace

import dns.edns
import dns.exception
import dns.message
import dns.query

from tests.support import load_script

runtime = load_script("network/runtime_policy.py")


@contextlib.contextmanager
def processes(args, config, root, fragments=None, ipv4_only=False):
    root.mkdir(parents=True, exist_ok=True)
    config = {**config, "logSocket": str(root / "dnstap.sock")}
    source = root / "policy.json"
    source.write_text(json.dumps(config))
    runtime.prepare(SimpleNamespace(policy=source, fragments=fragments or root / "route.d", dnsdist=args.dnsdist,
                    sing_box=None, provider=None, base=None, action="check", connections=None, bootstrap=False,
                    ipv4_only=ipv4_only, rules_directory=None, group=grp.getgrgid(os.getgid()).gr_name), root)
    check = subprocess.run([args.dnsdist, "--check-config", "-C", str(root / "dnsdist.conf")], capture_output=True, text=True)
    assert check.returncode == 0, check.stdout + check.stderr
    with contextlib.ExitStack() as stack:
        collector = json.loads(Path(args.collector_template).read_text())
        collector["pipelines"][0]["dnstap"]["sock-path"] = config["logSocket"]
        collector_config = root / "collector.json"
        collector_config.write_text(json.dumps(collector))
        running = {}
        logs = []

        def start(name, command, filename):
            path = root / filename
            log = stack.enter_context(path.open("w"))
            logs.append(path)
            running[name] = subprocess.Popen(command, stdout=log, stderr=log, stdin=subprocess.DEVNULL)

        def check_processes():
            for name, process in running.items():
                if process.poll() is not None:
                    raise AssertionError(f"{name} exited with status {process.returncode}")

        try:
            deadline = time.monotonic() + 30
            start("collector", [args.dnscollector, "-config", str(collector_config)], "events.jsonl")
            while not Path(config["logSocket"]).exists():
                check_processes()
                assert time.monotonic() < deadline, "collector dnstap socket did not become ready"
                time.sleep(0.05)
            for group in config["groups"]:
                if (root / f"race-{group}.json").exists():
                    start(f"race-{group}", [args.dnsproxy, "--config-path", str(root / f"race-{group}.json")], f"race-{group}.log")
            start("dnsdist", [args.dnsdist, "--supervised", "--disable-syslog", "-C", str(root / "dnsdist.conf")], "dnsdist.log")
            pending = {(port, tcp): "not queried" for port in (config["frontPort"], config["bootstrapPort"])
                       for tcp in (False, True)}
            while pending:
                check_processes()
                for port, tcp in list(pending):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise AssertionError(f"DNS stack not ready after 30s: {pending}")
                    try:
                        response = query(port, "ready.example.org", tcp=tcp, timeout=min(1, remaining))
                    except (OSError, EOFError, dns.exception.Timeout) as error:
                        pending[port, tcp] = f"{type(error).__name__}: {error}"
                    else:
                        if response.rcode() == 0 and response.answer:
                            del pending[port, tcp]
                        else:
                            pending[port, tcp] = response.to_text()
                if pending:
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
            check_processes()
            yield
        except BaseException:
            for path in logs:
                print(path.name + ":\n" + path.read_text(errors="replace")[-12000:], file=sys.stderr, flush=True)
            raise
        finally:
            for process in running.values():
                process.terminate()
            deadline = time.monotonic() + 5
            for process in running.values():
                try:
                    process.wait(timeout=max(0, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def query(port, name, kind="A", tcp=False, ecs=False, address="127.0.0.1", timeout=8):
    message = dns.message.make_query(name, kind)
    if ecs:
        message.use_edns(options=[dns.edns.ECSOption("192.0.2.0", 24)])
    return (dns.query.tcp if tcp else dns.query.udp)(message, address, port=port, timeout=timeout)


def marker(message):
    return message.answer[0][0].to_text() if message.answer else None


def read_events(path):
    events = []
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not event.get("extracted", {}).get("dns_payload"):
            continue
        message = dns.message.from_wire(base64.b64decode(event["extracted"]["dns_payload"]))
        events.append({"name": message.question[0].name.to_text().rstrip(".").lower(), "message": message,
                       "identity": event["dnstap"]["identity"], "policy": json.loads(event["dnstap"]["extra"])})
    return events
