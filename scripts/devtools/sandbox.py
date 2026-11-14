"""Launch a declared tool with project-local storage and explicit host access."""
from contextlib import ExitStack
import fcntl
import grp
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import tempfile
import time


def main():
    policy = json.loads(Path(sys.argv[1]).read_text())
    arguments = sys.argv[2:]
    root = Path(subprocess.check_output(
        [policy["git"], "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    cwd, home = Path.cwd(), Path.home()
    os.umask(0o077)

    def directory(path):
        if not path.resolve().is_relative_to(root):
            raise RuntimeError(f"tool directory must stay inside the project: {path}")
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
        return path

    storage = directory(root / "tmp/.cache/nixos-config-tools" / policy["name"])
    filesystem = subprocess.check_output(
        [policy["stat"], "-f", "-c", "%T", str(storage)], text=True).strip()
    if filesystem in {"tmpfs", "ramfs"}:
        raise RuntimeError(f"{storage} is on {filesystem}; use the laptop's persistent workspace")
    cache, logs, temporary = [directory(storage / name) for name in ("cache", "logs", "tmp")]
    rules = "".join(
        f"e {json.dumps(str(path).replace('%', '%%'), ensure_ascii=False)} - - - {age} -\n"
        for path, age in ((cache, "30d"), (logs, "30d"), (temporary, "1d")))
    subprocess.run([policy["tmpfiles"], "--user", "--clean", "-"], input=rules, text=True, check=True)

    with ExitStack() as stack:
        def lock(path):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            stack.callback(os.close, fd)
            fcntl.flock(fd, fcntl.LOCK_SH)

        lock(cache)
        lock(logs)
        work = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="run-", dir=temporary)))
        lock(work)
        args = [policy["bwrap"], "--unshare-all", "--unshare-user", "--disable-userns",
                "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--clearenv",
                "--tmpfs", "/", "--proc", "/proc", "--dev", "/dev"]
        if policy["network"]:
            args += ["--share-net"]

        def mount(source, destination=None, writable=False):
            source = Path(source)
            if source.exists():
                args.extend(["--bind" if writable else "--ro-bind", str(source),
                             str(destination or source)])

        if policy["nix"]:
            mount("/nix/store")
            mount("/nix/var/nix/daemon-socket")
            mount("/etc/nix")
            mount(home / ".config/nix")
        else:
            args += ["--dir", "/nix/store"]
            for path in Path(policy["closure"]).read_text().splitlines():
                mount(path)
        for path in ("/etc/resolv.conf", "/etc/hosts"):
            mount(path)
        mount(policy["ca"], "/etc/ssl/certs/ca-certificates.crt")
        mount(policy["nsswitch"], "/etc/nsswitch.conf")
        args += ["--symlink", policy["shell"], "/bin/sh", "--symlink", policy["shell"], "/bin/bash",
                 "--dir", str(home / ".config")]
        passwd = work / "passwd"
        passwd.write_text(f"{pwd.getpwuid(os.getuid()).pw_name}:x:{os.getuid()}:{os.getgid()}:Tool:{home}:/bin/sh\n")
        group = work / "group"
        group.write_text(f"{grp.getgrgid(os.getgid()).gr_name}:x:{os.getgid()}:\n")
        mount(passwd, "/etc/passwd")
        mount(group, "/etc/group")
        masked = []
        if policy["project"]:
            mount(root)
            # Decrypted deployment files and other tools' credentials need separate grants.
            for name in ("tmp", ".wrangler"):
                if (root / name).exists():
                    args += ["--tmpfs", str(root / name)]
                    masked.append(str(root / name))
        for name in policy["readable"]:
            mount(root / name)
        for name in policy["writable"]:
            mount(directory(root / name), writable=True)
        mount(cache, writable=True)
        mount(logs, writable=True)
        mount(work, "/tmp", writable=True)

        environment = {
            "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(cache), "XDG_STATE_HOME": "/tmp/state", "TMPDIR": "/tmp",
            "PATH": policy["path"], "LANG": "C.UTF-8", "PWD": str(cwd),
            "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
        }
        if policy["nix"]:
            nix_cache = home / ".cache/nix"
            nix_cache.mkdir(parents=True, exist_ok=True)
            mount(nix_cache, cache / "nix", writable=True)
            environment["NIX_REMOTE"] = "daemon"
        if policy["database"]:
            # oranc opens the live SQLite database and creates temporary files beside it.
            mount("/nix/var/nix/db", writable=True)
        if policy["ssh"]:
            # SSH maintains known_hosts with atomic replacements in this directory.
            (home / ".ssh").mkdir(mode=0o700, exist_ok=True)
            mount(home / ".ssh", writable=True)
            for path in Path("/etc/ssh").glob("*.pub"):
                mount(path)
            for path in ("/etc/ssh/ssh_config", "/etc/ssh/ssh_known_hosts"):
                mount(path)
            mount(f"/run/site-identity/{home.name}/current")
            socket = os.environ.get("SSH_AUTH_SOCK")
            if socket:
                mount(socket)
                environment["SSH_AUTH_SOCK"] = socket
            configuration = os.environ.get("SSH_CONFIG_FILE")
            if configuration:
                mount(Path(configuration).absolute())
                environment["SSH_CONFIG_FILE"] = configuration
        if policy["worker"]:
            mount(directory(root / ".wrangler"), home / ".config/.wrangler", writable=True)
            environment.update(WRANGLER_SEND_METRICS="false", WRANGLER_LOG_PATH=str(logs),
                               WRANGLER_CACHE_DIR=str(cache), MINIFLARE_CACHE_DIR=str(cache / "miniflare"))
            if (cwd / "wrangler.json").is_file():
                mount(cwd)
                directory(cwd / ".wrangler")
                mount(work, cwd / ".wrangler", writable=True)
            else:
                args += ["--dir", str(cwd)]

        variables = ["TERM", "COLORTERM", "NO_COLOR", "CI"] + policy["passEnvironment"]
        if policy["network"]:
            variables += ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                          "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        environment.update({key: os.environ[key] for key in variables if key in os.environ})
        for key, value in environment.items():
            args += ["--setenv", key, value]
        for path in masked:
            args += ["--remount-ro", path]
        info_read, info_write = os.pipe()
        args += ["--chdir", str(cwd), "--remount-ro", "/", "--as-pid-1", "--info-fd", str(info_write),
                 "--", policy["init"], "-g", "--", policy["command"], *arguments]
        process = subprocess.Popen(args, pass_fds=(info_write,))
        os.close(info_write)
        child_fd, deadline = None, None

        # Signal the namespace init: it forwards to the tool's process group.
        # Waiting inside a signal handler would re-enter Popen's waitpid lock.
        def stop(signum, _frame):
            nonlocal deadline
            deadline = time.monotonic() + 30
            if child_fd is not None:
                try:
                    signal.pidfd_send_signal(child_fd, signum)
                except ProcessLookupError:
                    pass

        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, stop)
        with os.fdopen(info_read) as information:
            data = information.read()
        if data:
            try:
                child_fd = os.pidfd_open(json.loads(data)["child-pid"])
                stack.callback(os.close, child_fd)
            except ProcessLookupError:
                pass
        while True:
            try:
                result = process.wait(timeout=1)
                break
            except subprocess.TimeoutExpired:
                if deadline is not None and time.monotonic() >= deadline:
                    process.kill()
        return result if result >= 0 else 128 - result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"tool sandbox: {error}", file=sys.stderr)
        sys.exit(1)
