"""Run a command or interactive shell with native traffic and real-address DNS."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pwd
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time

from run_excluded import excluded


def write_json(path, value, mode=0o600):
    candidate = path.with_suffix(".new")
    candidate.write_text(json.dumps(value))
    candidate.chmod(mode)
    candidate.replace(path)


def settings(policy):
    path = Path(policy["state"]) / "dns.json"
    return json.loads(path.read_text()) if path.exists() else policy["upstreams"]


def resolver_command(policy, directory, address, upstreams):
    account = pwd.getpwnam(policy["user"])
    config = directory / "resolver.json"
    write_json(config, {
        "listen-addrs": [address], "listen-ports": [53],
        "upstream": upstreams + (["[/ts.net/]100.100.100.100"] if policy["tailnet"] else []),
        "bootstrap": policy["bootstrap"], "upstream-mode": "parallel",
        "cache": True, "cache-size": 1048576,
    }, 0o640)
    os.chown(config, 0, account.pw_gid)
    return [policy["setpriv"], f"--reuid={account.pw_uid}", f"--regid={account.pw_gid}",
            "--clear-groups", "--pdeathsig=TERM", "--inh-caps=-all,+net_bind_service",
            "--ambient-caps=-all,+net_bind_service", "--bounding-set=-all,+net_bind_service",
            policy["dnsproxy"], "--config-path", str(config)]


def ready(process, address):
    deadline = time.monotonic() + 10
    while process.poll() is None and time.monotonic() < deadline:
        try:
            with socket.create_connection((address, 53), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("DNS resolver did not start")


@contextlib.contextmanager
def temporary_resolver(policy, directory, upstreams):
    # Linux routes the whole 127/8 network locally. Each invocation gets its
    # own DNS address without changing the host network namespace or routes.
    address = f"127.53.{secrets.randbelow(254) + 1}.{secrets.randbelow(254) + 1}"
    with (directory / "resolver.log").open("w+") as log:
        process = subprocess.Popen(resolver_command(policy, directory, address, upstreams),
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            try:
                ready(process, address)
            except RuntimeError:
                log.seek(0)
                raise RuntimeError("DNS resolver did not start: " + log.read()[-4096:]) from None
            yield address
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def manage_dns(policy, action, upstreams):
    state = Path(policy["state"])
    with (state / "dns.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = state / "dns.json"
        if action != "show":
            old = json.loads(path.read_text()) if path.exists() else None
            desired = upstreams if action == "set" else policy["upstreams"]
            with tempfile.TemporaryDirectory(prefix="check-", dir=state) as name:
                directory = Path(name)
                directory.chmod(0o711)
                with temporary_resolver(policy, directory, desired):
                    pass
            if action == "set":
                write_json(path, desired)
            else:
                path.unlink(missing_ok=True)
            try:
                subprocess.run([policy["systemctl"], "restart", "site-network-exclude-dns"], check=True)
                with socket.create_connection((policy["address"], 53), timeout=5):
                    pass
            except (OSError, subprocess.CalledProcessError):
                if old is None:
                    path.unlink(missing_ok=True)
                else:
                    write_json(path, old)
                subprocess.run([policy["systemctl"], "restart", "site-network-exclude-dns"], check=False)
                raise RuntimeError("DNS update failed; restored the previous settings")
        print("DNS source: " + ("current boot" if path.exists() else "system defaults"))
        print("\n".join(settings(policy)))


def mount_file(policy, source, destination):
    subprocess.run([policy["mount"], "--bind", str(source), destination], check=True)
    subprocess.run([policy["mount"], "-o", "remount,bind,ro", destination], check=True)


def command_environment(policy, directory, address, uid):
    os.unshare(os.CLONE_NEWNS)
    subprocess.run([policy["mount"], "--make-rprivate", "/"], check=True)
    resolv = directory / "resolv.conf"
    # Preserve search domains and resolver options used by the login session.
    lines = [line for line in Path("/etc/resolv.conf").read_text().splitlines()
             if line.split()[:1] in (["search"], ["domain"], ["options"])]
    resolv.write_text(f"nameserver {address}\n" + "\n".join(lines) + "\n")
    resolv.chmod(0o644)
    mount_file(policy, resolv, "/etc/resolv.conf")
    nss = directory / "nsswitch.conf"
    nss.write_text("\n".join("hosts: files dns" if line.lstrip().startswith("hosts:") else line
                             for line in Path("/etc/nsswitch.conf").read_text().splitlines()) + "\n")
    nss.chmod(0o644)
    mount_file(policy, nss, "/etc/nsswitch.conf")
    if Path("/run/nscd").exists():
        empty = directory / "nscd"
        empty.mkdir(mode=0o755)
        mount_file(policy, empty, "/run/nscd")
    context = directory / "context.json"
    write_json(context, {"uid": uid, "address": address}, 0o644)
    mount_file(policy, context, policy["state"] + "/context.json")


def wait_command(process):
    # Terminal signals already reach the foreground process group. Keep the
    # supervisor alive to reclaim its resolver and mounts after the child exits.
    previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGQUIT)}
    previous.update({sig: signal.signal(sig, lambda received, frame: process.send_signal(received))
                     for sig in (signal.SIGTERM, signal.SIGHUP)})
    try:
        code = process.wait()
        return code if code >= 0 else 128 - code
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def privileged(policy, request_path):
    if os.geteuid() != 0 or not excluded(Path("/proc/self/cgroup").read_text()):
        raise RuntimeError("Mullvad process exclusion is not available")
    with open(request_path) as handle:
        uid = int(os.environ.get("SUDO_UID", os.getuid()))
        if os.fstat(handle.fileno()).st_uid != uid:
            raise RuntimeError("request owner differs from the calling user")
        request = json.load(handle)
    account = pwd.getpwuid(uid)
    if request["action"] != "run":
        manage_dns(policy, request["action"], request["dns"])
        return 0
    with tempfile.TemporaryDirectory(prefix="session-", dir=policy["state"]) as name:
        directory = Path(name)
        directory.chmod(0o711)
        resolver = (temporary_resolver(policy, directory, request["dns"]) if request["dns"]
                    else contextlib.nullcontext(policy["address"]))
        with resolver as address:
            command_environment(policy, directory, address, uid)
            process = subprocess.Popen(request["command"], cwd=request["cwd"], env=request["environment"],
                                       user=uid, group=account.pw_gid,
                                       extra_groups=os.getgrouplist(account.pw_name, account.pw_gid))
            return wait_command(process)


def main():
    policy_path = sys.argv[1]
    policy = json.loads(Path(policy_path).read_text())
    args = sys.argv[2:]
    state = Path(policy["state"])
    if args == ["--serve"]:
        if not excluded(Path("/proc/self/cgroup").read_text()):
            raise RuntimeError("Mullvad process exclusion is not available")
        if not (state / "context.json").exists():
            write_json(state / "context.json", {}, 0o644)
        command = resolver_command(policy, state, policy["address"], settings(policy))
        process = subprocess.Popen(command)
        try:
            ready(process, policy["address"])
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
                address = os.environ["NOTIFY_SOCKET"]
                channel.connect("\0" + address[1:] if address.startswith("@") else address)
                channel.sendall(b"READY=1")
            return wait_command(process)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
    if args[:1] == ["--privileged"]:
        return privileged(policy, args[1])
    parser = argparse.ArgumentParser(prog="network-exclude", description=__doc__,
                                     epilog="Shared DNS: network-exclude dns {show,reset,set SERVER...}")
    if args[:1] == ["dns"]:
        parser.add_argument("action", choices=["show", "reset", "set"])
        parser.add_argument("servers", nargs="*")
        parsed = parser.parse_args(args[1:])
        if (parsed.action == "set") != bool(parsed.servers):
            parser.error("dns set requires one or more servers; show/reset take no servers")
        request = {"action": parsed.action, "dns": parsed.servers}
    else:
        parser.add_argument("--dns", action="append", help="DNS upstream for this invocation; may be repeated")
        parser.add_argument("command", nargs=argparse.REMAINDER)
        parsed = parser.parse_args(args)
        command = parsed.command
        if command[:1] == ["--"]:
            command = command[1:]
        command = command or [os.environ.get("SHELL") or pwd.getpwuid(os.getuid()).pw_shell, "-i"]
        context = json.loads((state / "context.json").read_text()) if (state / "context.json").exists() else {}
        if not parsed.dns and context.get("uid") == os.getuid() and excluded(Path("/proc/self/cgroup").read_text()):
            os.execvpe(command[0], command, os.environ)
        request = {"action": "run", "dns": parsed.dns, "command": command,
                   "cwd": os.getcwd(), "environment": dict(os.environ)}
    # sudo transports only the request filename. User environment is restored
    # after dropping privileges, including PATH and SSH_AUTH_SOCK.
    with tempfile.NamedTemporaryFile(mode="w", prefix="network-exclude-", suffix=".json",
                                     dir=os.environ.get("XDG_RUNTIME_DIR")) as handle:
        json.dump(request, handle)
        handle.flush()
        command = [policy["exclude"], policy["python"], "-Es", __file__, policy_path,
                   "--privileged", handle.name]
        if os.geteuid() != 0:
            command = [policy["sudo"], "--", *command]
        return wait_command(subprocess.Popen(command))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"network-exclude: {error}", file=sys.stderr)
        sys.exit(1)
