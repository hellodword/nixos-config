"""Playwright CDP controller for sandboxed Electron / VS Code windows across PID namespaces."""

from contextlib import contextmanager
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import time

from playwright.sync_api import (
    Error as PlaywrightError,
    TimeoutError as PlaywrightTimeoutError,
    expect,
)


def wait_for(function, description, timeout=90, interval=0.5):
    deadline = time.monotonic() + timeout
    while True:
        result = function()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out: " + description)
        time.sleep(interval)


@contextmanager
def cleanup_step(description):
    primary = sys.exception()
    try:
        yield
    except Exception as error:
        if primary is None:
            raise
        primary.add_note(description + ": " + str(error))
        print(description + ": " + str(error), flush=True)


@contextmanager
def managed_process(log_path, arguments):
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as log:
        process = subprocess.Popen(arguments, stdout=log, stderr=log, start_new_session=True)
        try:
            yield process
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)


def attach_cdp(playwright, port, check_alive, timeout=90):
    last_error = None

    def connect():
        nonlocal last_error
        check_alive()
        try:
            return playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{port}", timeout=3000)
        except PlaywrightError as error:
            if not isinstance(error, PlaywrightTimeoutError) and not any(
                reason in str(error)
                for reason in ("ECONNREFUSED", "ECONNRESET", "socket hang up")
            ):
                raise
            last_error = error
            return None

    try:
        return wait_for(connect, "application debugging endpoint", timeout=timeout)
    except AssertionError as error:
        if last_error:
            error.add_note("Last CDP connection error: " + str(last_error))
        raise


def gui_pids(port, namespace_pid=None, executable="code"):
    """Locate the main Electron GUI process across desktop scopes and sandbox PID namespaces."""
    accepted_names = {executable, executable + "-wrapped", "electron"}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            arguments = (entry / "cmdline").read_bytes().replace(b"\0", b" ").split()
            if f"--remote-debugging-port={port}".encode() not in arguments:
                continue
            if any(arg.startswith(b"--type=") for arg in arguments):
                continue
            if namespace_pid is not None:
                ids = next(
                    line.split()[1:]
                    for line in (entry / "status").read_text().splitlines()
                    if line.startswith("NSpid:")
                )
                if ids[-1] != str(namespace_pid):
                    continue
            else:
                if Path(os.fsdecode(arguments[0])).name.lstrip(".") not in accepted_names:
                    continue
                if b"ELECTRON_RUN_AS_NODE=1" in (entry / "environ").read_bytes().split(b"\0"):
                    continue
            yield int(entry.name)
        except (FileNotFoundError, ProcessLookupError, PermissionError, StopIteration):
            continue


def retain_wm_windows(artifacts_dir, name):
    artifacts_dir = Path(artifacts_dir)
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
    wm = "swaymsg" if "sway" in desktop else "i3-msg" if "i3" in desktop else None
    if wm and shutil.which(wm):
        tree = subprocess.run(
            [wm, "-t", "get_tree"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
        (artifacts_dir / (name + "-windows.json")).write_text(tree)


@contextmanager
def vscode_electron_session(
    playwright,
    arguments,
    *,
    port=9223,
    artifacts_dir,
    name="vscode",
    state_dict=None,
    on_phase=None,
    on_failure=None,
):
    """Launch VS Code with CDP enabled, track its real GUI process via NSpid, and yield the workbench Page."""
    artifacts_dir = Path(artifacts_dir)
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    state = state_dict if state_dict is not None else {}
    network_log = artifacts_dir / (name + "-network.json")

    def emit_phase(phase_name, **details):
        if on_phase is not None:
            on_phase(phase_name, **details)
        else:
            state.update(details, phase=phase_name)

    emit_phase(
        "launch",
        command=arguments,
        executable=shutil.which(arguments[0]),
        session=os.environ.get("XDG_CURRENT_DESKTOP"),
        sessionType=os.environ.get("XDG_SESSION_TYPE"),
    )

    with managed_process(
        artifacts_dir / (name + ".log"),
        [*arguments, f"--remote-debugging-port={port}", f"--log-net-log={network_log}"],
    ) as process:
        browser = page = gui_process = None

        def watch_gui(pid):
            nonlocal gui_process
            group = next(
                line[3:]
                for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines()
                if line.startswith("0::")
            )
            state["guiUnit"] = next(
                part
                for part in reversed(Path(group).parts)
                if part.endswith((".scope", ".service"))
            )
            if state.get("guiPid") == pid:
                return
            descriptor = os.pidfd_open(pid)
            if gui_process is not None:
                os.close(gui_process)
            gui_process = descriptor
            state["guiPid"] = pid
            state["guiCommand"] = Path(f"/proc/{pid}/cmdline").read_text().rstrip("\0").split("\0")
            try:
                environment = dict(
                    item.split("=", 1)
                    for item in Path(f"/proc/{pid}/environ").read_text().split("\0")
                    if "=" in item
                )
                state["guiEnvironment"] = {
                    key: environment.get(key)
                    for key in ("NIXOS_OZONE_WL", "GTK_IM_MODULE", "GTK_IM_MODULE_FILE", "WAYLAND_DISPLAY")
                }
            except PermissionError as error:
                state["guiEnvironmentError"] = str(error)

        def alive():
            if gui_process is None:
                pid = next(gui_pids(port), None)
                if pid is not None:
                    watch_gui(pid)
            if gui_process is not None and select.select([gui_process], [], [], 0)[0]:
                raise AssertionError(
                    f"{name} GUI process {state.get('guiPid')} exited during {state.get('phase')}"
                )
            if process.poll() not in (None, 0):
                raise AssertionError(f"{name} launcher exited with {process.returncode}")
            if browser is not None and not browser.is_connected():
                raise AssertionError(f"{name} debugging connection closed during {state.get('phase')}")

        try:
            emit_phase("debugging-endpoint", launcherPid=process.pid)
            browser = attach_cdp(playwright, port, alive)
            session = browser.new_browser_cdp_session()
            processes = session.send("SystemInfo.getProcessInfo")
            state["debuggerPid"] = next(
                int(item["id"])
                for item in processes["processInfo"]
                if item["type"] == "browser"
            )
            candidates = list(gui_pids(port, state["debuggerPid"]))
            assert len(candidates) == 1, f"Cannot identify {name} GUI in this execution: {candidates}"
            watch_gui(candidates[0])
            emit_phase("window", runtime=session.send("Browser.getVersion"), guiPid=state["guiPid"])

            def application_page():
                alive()
                for context in browser.contexts:
                    for candidate in context.pages:
                        if "workbench" in candidate.url:
                            return candidate
                if browser.contexts:
                    try:
                        browser.contexts[0].wait_for_event("page", timeout=500)
                    except PlaywrightTimeoutError:
                        pass
                return None

            page = wait_for(application_page, "application window")
            page.set_default_timeout(30000)
            page.on(
                "requestfailed",
                lambda request: print(
                    name + " request failed:",
                    request.url.partition("?")[0],
                    request.failure,
                    flush=True,
                ),
            )
            emit_phase("window-ready", userAgent=page.evaluate("navigator.userAgent"))
            retain_wm_windows(artifacts_dir, name)
            yield page
            retain_wm_windows(artifacts_dir, name)
            page.screenshot(path=str(artifacts_dir / (name + ".png")))
        except Exception as error:
            if on_failure is not None:
                on_failure(error)
            if page is not None:
                with cleanup_step(name + " text"):
                    (artifacts_dir / (name + "-failure.txt")).write_text(
                        page.locator("body").inner_text(timeout=5000)
                    )
                with cleanup_step(name + " accessibility"):
                    accessibility = page.locator("body").aria_snapshot(timeout=5000)
                    (artifacts_dir / (name + "-accessibility.txt")).write_text(accessibility)
                    print(name + " window at failure:\n" + accessibility, flush=True)
                with cleanup_step(name + " screenshot"):
                    page.screenshot(path=str(artifacts_dir / (name + "-failure.png")), timeout=5000)
            with cleanup_step(name + " windows"):
                retain_wm_windows(artifacts_dir, name)
            raise
        finally:
            with cleanup_step(name + " process discovery"):
                if gui_process is None:
                    pid = next(gui_pids(port), None)
                    if pid is not None:
                        watch_gui(pid)
            with cleanup_step(name + " logs"):
                code_logs = Path.home() / ".config/Code/logs"
                if name == "vscode" and code_logs.exists():
                    dest_logs = artifacts_dir / "vscode-logs"
                    shutil.rmtree(dest_logs, ignore_errors=True)
                    subprocess.run(
                        ["cp", "-a", str(code_logs), str(dest_logs)],
                        check=True,
                        timeout=10,
                    )
            emit_phase("closing", launcherExit=process.poll())
            try:
                if page is not None and not page.is_closed():
                    page.close(run_before_unload=True)
            except PlaywrightError:
                pass
            if gui_process is not None:
                try:
                    if not select.select([gui_process], [], [], 10)[0]:
                        signal.pidfd_send_signal(gui_process, signal.SIGTERM)
                        select.select([gui_process], [], [], 10)
                except ProcessLookupError:
                    pass
                finally:
                    state["guiStopped"] = bool(select.select([gui_process], [], [], 0)[0])
                    os.close(gui_process)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            emit_phase("closed", launcherExit=process.poll())


def reopen_in_devcontainer(
    page,
    workspace,
    *,
    expected_host_label="Dev Container",
    timeout=240,
):
    """Trigger Reopen in Container, wait for the container to start, and verify remote status bar attachment."""
    workspace = Path(workspace)
    reopen_btn = page.get_by_role("button", name="Reopen in Container", exact=True)
    try:
        reopen_btn.click(timeout=20000)
    except PlaywrightError:
        # Trigger via Command Palette when notification toast is suppressed or delayed.
        page.keyboard.press("F1")
        palette = page.locator(".quick-input-widget input.input")
        palette.wait_for(timeout=15000)
        palette.fill(">Dev Containers: Reopen in Container")
        page.locator(".quick-input-list .monaco-list-row", has_text="Reopen in Container").first.click(
            timeout=15000
        )

    container_id = wait_for(
        lambda: subprocess.run(
            ["docker", "ps", "-q", "--filter", f"label=devcontainer.local_folder={workspace}"],
            capture_output=True,
            text=True,
            check=True,
            timeout=15,
        ).stdout.strip(),
        f"development container for {workspace}",
        timeout=timeout,
    ).splitlines()[0]

    deadline = time.monotonic() + timeout
    last_host_text = ""
    while time.monotonic() < deadline:
        try:
            page.locator(".monaco-workbench").wait_for(timeout=5000)
            remote = page.locator('.statusbar-item[id="status.host"]')
            last_host_text = remote.inner_text(timeout=5000)
            if expected_host_label in last_host_text:
                return container_id
        except Exception:
            pass
        time.sleep(1)
    raise AssertionError(
        f"VS Code did not finish attaching to Dev Container (expected {expected_host_label!r}, last status.host={last_host_text!r})"
    )


def open_integrated_terminal(page, timeout=30000):
    """Open and focus the VS Code integrated terminal textbox."""
    page.keyboard.press("Control+Shift+Backquote")
    terminal_input = page.get_by_role("textbox", name=re.compile(r"^Terminal \d+,"))
    terminal_input.wait_for(timeout=timeout)
    terminal_input.focus()
    expect(terminal_input).to_be_focused(timeout=timeout)
    return terminal_input


def run_integrated_terminal_command(page, command, result_file, *, timeout=60):
    """Execute a shell command in the focused integrated terminal and wait for its sentinel output file."""
    result_file = Path(result_file)
    result_file.unlink(missing_ok=True)
    terminal_input = page.get_by_role("textbox", name=re.compile(r"^Terminal \d+,"))
    if not terminal_input.is_visible():
        terminal_input = open_integrated_terminal(page)
    else:
        terminal_input.focus()
        expect(terminal_input).to_be_focused(timeout=15000)
    page.keyboard.type(command + "\n", delay=15)
    wait_for(lambda: result_file.exists(), f"terminal command output {result_file}", timeout=timeout)
    return result_file.read_text()
