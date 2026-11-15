"""Production resolver stack, queries and dnstap observations for process scenarios."""
import base64
import contextlib
import grp
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from types import SimpleNamespace

import dns.edns
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
        events = stack.enter_context((root / "events.jsonl").open("w"))
        running = [subprocess.Popen([args.dnscollector, "-config", str(collector_config)], stdout=events, stderr=events)]
        for _ in range(100):
            if Path(config["logSocket"]).exists():
                break
            if running[0].poll() is not None:
                raise AssertionError((root / "events.jsonl").read_text())
            time.sleep(0.05)
        for group in config["groups"]:
            if not (root / f"race-{group}.json").exists():
                continue
            log = stack.enter_context((root / f"race-{group}.log").open("w"))
            running.append(subprocess.Popen([args.dnsproxy, "--config-path", str(root / f"race-{group}.json")], stdout=log, stderr=log))
        log = stack.enter_context((root / "dnsdist.log").open("w"))
        running.append(subprocess.Popen([args.dnsdist, "--supervised", "--disable-syslog", "-C", str(root / "dnsdist.conf")], stdout=log, stderr=log, stdin=subprocess.DEVNULL))
        try:
            for _ in range(100):
                if any(p.poll() is not None for p in running):
                    raise AssertionError("DNS process exited: " + (root / "dnsdist.log").read_text())
                try:
                    with socket.create_connection(("127.0.0.1", config["frontPort"]), timeout=0.1):
                        pass
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("DNS stack not ready")
            assert query(config["frontPort"], "ready.example.org").rcode() == 0
            yield
        except BaseException:
            for handle in (root / "dnsdist.log", root / "race-cn.log", root / "race-global.log", root / "events.jsonl"):
                if handle.exists():
                    print(handle.name + ":\n" + handle.read_text()[-12000:], flush=True)
            raise
        finally:
            for process in running:
                process.terminate()
            for process in running:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def query(port, name, kind="A", tcp=False, ecs=False, address="127.0.0.1"):
    message = dns.message.make_query(name, kind)
    if ecs:
        message.use_edns(options=[dns.edns.ECSOption("192.0.2.0", 24)])
    return (dns.query.tcp if tcp else dns.query.udp)(message, address, port=port, timeout=8)


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
