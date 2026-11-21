"""Exercise the installed applications inside the logged-in synthetic desktop."""

import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import time
from contextlib import contextmanager

from playwright.sync_api import Error as PlaywrightError, TimeoutError as PlaywrightTimeoutError, expect, sync_playwright


ROOT = Path.home() / "application-workspace"
ARTIFACTS = ROOT / "artifacts"
STARTED = time.monotonic()
RUN = {"phases": []}


def phase(name, **details):
    RUN.update(details, phase=name, seconds=time.monotonic() - STARTED)
    RUN["phases"].append({"phase": name, "seconds": RUN["seconds"]})
    path = ARTIFACTS / (RUN["application"] + "-state.json")
    pending = path.with_suffix(".pending")
    pending.write_text(json.dumps(RUN, ensure_ascii=False, indent=2) + "\n")
    pending.replace(path)
    print(json.dumps({"application": RUN["application"], "phase": name,
                      "seconds": RUN["seconds"], **details}, ensure_ascii=False), flush=True)


def failure(error):
    RUN.setdefault("failure", {"phase": RUN.get("phase"),
                               "type": type(error).__name__, "message": str(error)})


@contextmanager
def cleanup(description):
    primary = sys.exception()
    try:
        yield
    except Exception as error:
        if primary is None:
            raise
        primary.add_note(description + ": " + str(error))
        print(description + ": " + str(error), flush=True)


def wait_for(function, description, timeout=90):
    deadline = time.monotonic() + timeout
    while True:
        result = function()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out: " + description)
        time.sleep(0.5)


@contextmanager
def application(name, arguments):
    with (ARTIFACTS / (name + ".log")).open("a") as log:
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


def attach(playwright, port, check_alive):
    last_error = None
    def connect():
        nonlocal last_error
        check_alive()
        try:
            return playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{port}", timeout=3000)
        except PlaywrightError as error:
            if not isinstance(error, PlaywrightTimeoutError) and not any(
                reason in str(error) for reason in ("ECONNREFUSED", "ECONNRESET", "socket hang up")
            ):
                raise
            last_error = error
            return None
    try:
        return wait_for(connect, "application debugging endpoint")
    except AssertionError as error:
        if last_error:
            error.add_note("Last CDP connection error: " + str(last_error))
        raise


def gui_pids(name, port, namespace_pid=None):
    """Find this debuggee across desktop scopes and sandbox PID namespaces."""
    executable = "code"
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            # Electron can rewrite argv into one space-separated process title.
            arguments = (entry / "cmdline").read_bytes().replace(b"\0", b" ").split()
            if f"--remote-debugging-port={port}".encode() not in arguments:
                continue
            if any(arg.startswith(b"--type=") for arg in arguments):
                continue
            if namespace_pid is not None:
                # CDP reports the PID inside the application's sandbox.
                ids = next(line.split()[1:] for line in (entry / "status").read_text().splitlines()
                           if line.startswith("NSpid:"))
                if ids[-1] != str(namespace_pid):
                    continue
            else:
                if Path(os.fsdecode(arguments[0])).name.lstrip(".") not in (executable, executable + "-wrapped", "electron"):
                    continue
                if b"ELECTRON_RUN_AS_NODE=1" in (entry / "environ").read_bytes().split(b"\0"):
                    continue
            yield int(entry.name)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue


def retain_windows(name):
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
    wm = "swaymsg" if "sway" in desktop else "i3-msg" if "i3" in desktop else None
    if wm:
        tree = subprocess.run([wm, "-t", "get_tree"], check=True, capture_output=True,
                              text=True, timeout=5).stdout
        (ARTIFACTS / (name + "-windows.json")).write_text(tree)


@contextmanager
def electron(playwright, name, arguments, port):
    network_log = ARTIFACTS / (name + "-network.json")
    network_log.parent.mkdir(parents=True, exist_ok=True)
    phase("launch", command=arguments, executable=shutil.which(arguments[0]),
          session=os.environ.get("XDG_CURRENT_DESKTOP"),
          sessionType=os.environ.get("XDG_SESSION_TYPE"))
    with application(name, [*arguments, f"--remote-debugging-port={port}",
                            f"--log-net-log={network_log}"]) as process:
        browser = page = gui_process = None

        def watch_gui(pid):
            nonlocal gui_process
            group = next(line[3:] for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines()
                         if line.startswith("0::"))
            RUN["guiUnit"] = next(part for part in reversed(Path(group).parts)
                                  if part.endswith((".scope", ".service")))
            if RUN.get("guiPid") == pid:
                return
            descriptor = os.pidfd_open(pid)
            if gui_process is not None:
                os.close(gui_process)
            gui_process = descriptor
            RUN["guiPid"] = pid
            RUN["guiCommand"] = Path(f"/proc/{pid}/cmdline").read_text().rstrip("\0").split("\0")
            try:
                environment = dict(item.split("=", 1) for item in Path(f"/proc/{pid}/environ").read_text().split("\0") if "=" in item)
                RUN["guiEnvironment"] = {key: environment.get(key) for key in (
                    "NIXOS_OZONE_WL", "GTK_IM_MODULE", "GTK_IM_MODULE_FILE",
                )}
            except PermissionError as error:
                RUN["guiEnvironmentError"] = str(error)

        def alive():
            if gui_process is None:
                pid = next(gui_pids(name, port), None)
                if pid is not None:
                    watch_gui(pid)
            if gui_process is not None and select.select([gui_process], [], [], 0)[0]:
                raise AssertionError(f"{name} GUI process {RUN['guiPid']} exited during {RUN['phase']}")
            if process.poll() not in (None, 0):
                raise AssertionError(f"{name} launcher exited with {process.returncode}")
            if browser is not None and not browser.is_connected():
                raise AssertionError(f"{name} debugging connection closed during {RUN['phase']}")

        try:
            phase("debugging-endpoint", launcherPid=process.pid)
            browser = attach(playwright, port, alive)
            session = browser.new_browser_cdp_session()
            processes = session.send("SystemInfo.getProcessInfo")
            RUN["debuggerPid"] = next(int(item["id"]) for item in processes["processInfo"] if item["type"] == "browser")
            candidates = list(gui_pids(name, port, RUN["debuggerPid"]))
            assert len(candidates) == 1, f"Cannot identify {name} GUI in this execution: {candidates}"
            watch_gui(candidates[0])
            phase("window", runtime=session.send("Browser.getVersion"), guiPid=RUN["guiPid"])

            def application_page():
                alive()
                for context in browser.contexts:
                    for candidate in context.pages:
                        if "workbench" in candidate.url:
                            return candidate
                # Dispatch navigation events while waiting for the workbench.
                if browser.contexts:
                    try:
                        browser.contexts[0].wait_for_event("page", timeout=500)
                    except PlaywrightTimeoutError:
                        pass
                return None

            page = wait_for(application_page, "application window")
            page.set_default_timeout(30000)
            page.on("requestfailed", lambda request: print(
                name + " request failed:", request.url.partition("?")[0], request.failure, flush=True,
            ))
            phase("window-ready", userAgent=page.evaluate("navigator.userAgent"))
            retain_windows(name)
            yield page
            retain_windows(name)
            page.screenshot(path=str(ARTIFACTS / (name + ".png")))
        except Exception as error:
            failure(error)
            if page is not None:
                with cleanup(name + " text"):
                    (ARTIFACTS / (name + "-failure.txt")).write_text(page.locator("body").inner_text(timeout=5000))
                with cleanup(name + " accessibility"):
                    accessibility = page.locator("body").aria_snapshot(timeout=5000)
                    (ARTIFACTS / (name + "-accessibility.txt")).write_text(accessibility)
                    print(name + " window at failure:\n" + accessibility, flush=True)
                with cleanup(name + " screenshot"):
                    page.screenshot(path=str(ARTIFACTS / (name + "-failure.png")), timeout=5000)
            with cleanup(name + " windows"):
                retain_windows(name)
            raise
        finally:
            with cleanup(name + " process discovery"):
                if gui_process is None:
                    pid = next(gui_pids(name, port), None)
                    if pid is not None:
                        watch_gui(pid)
            # Retain main/renderer/extension logs even when no window was created.
            with cleanup(name + " logs"):
                if name == "vscode" and (Path.home() / ".config/Code/logs").exists():
                    subprocess.run(["cp", "-a", str(Path.home() / ".config/Code/logs"),
                                    str(ARTIFACTS / "vscode-logs")], check=True, timeout=10)
            phase("closing", launcherExit=process.poll())
            # Close the window before signalling Electron and its renderers.
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
                    RUN["guiStopped"] = bool(select.select([gui_process], [], [], 0)[0])
                    os.close(gui_process)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            phase("closed", launcherExit=process.poll())


def input_observer(evaluate, expected="你好"):
    """Observe real IME delivery in a DOM input or a native EditContext."""
    evaluate("""element => {
        const context = element.editContext;
        const state = { composing: false, committed: '', events: [] };
        const text = () => context ? context.text : (element.value ?? element.textContent);
        const receive = event => {
            if (event.type === 'compositionstart') {
                state.composing = true;
                state.committed = '';
            }
            if (event.type === 'compositionend') {
                state.composing = false;
                state.committed = event.data || text();
            }
            if (event.type === 'input' && !event.isComposing && event.data) {
                state.committed += event.data;
            }
            state.events.push({type: event.type, data: event.data ?? event.text ?? '',
                               time: performance.now(), composing: event.isComposing});
            state.events = state.events.slice(-20);
        };
        for (const target of context ? [element, context] : [element]) {
            for (const event of ['compositionstart', 'compositionupdate', 'compositionend', 'input', 'textupdate']) {
                target.addEventListener(event, receive);
            }
        }
        element.applicationInput = () => ({...state, text: text(),
            nativeEditContext: Boolean(context), connected: element.isConnected,
            focused: document.hasFocus() && document.activeElement === element});
    }""")

    def observe(stage):
        state = evaluate("element => element.applicationInput()")
        if stage == "preedit":
            preedit = " ".join(event["data"] for event in state["events"]) + " " + state["text"]
            complete = "nihao" in re.sub(r"[\s'’]", "", preedit) or expected in preedit
            state["ready"] = state["focused"] and state["composing"] and complete
        else:
            state["ready"] = state["focused"] and not state["composing"] and expected in state["committed"]
        return state
    return observe


def input_json(name, value):
    pending = ROOT / (name + ".pending")
    pending.write_text(json.dumps(value, ensure_ascii=False))
    pending.replace(ROOT / name)


def ui_input(*actions, window, observe=None):
    """Acknowledge application receipt while the VM owns the keyboard."""
    request_id = str(time.monotonic_ns())
    request = ROOT / "input-request.json"
    acknowledgement = ROOT / "input-complete"
    progress = ROOT / "input-progress.json"
    started = time.monotonic()
    # The driver has 90 seconds for input, then captures Fcitx and the window
    # before reporting failure. Keep the application open for those diagnostics.
    deadline = started + 165
    history, last = [], None
    input_json(request.name, {"id": request_id, "actions": actions, "window": window})
    try:
        while time.monotonic() < deadline:
            if progress.exists():
                phase = json.loads(progress.read_text())
                if phase["id"] == request_id:
                    if phase.get("error"):
                        raise AssertionError(phase["error"])
                    if phase["phase"] in ("preedit", "committed"):
                        state = observe(phase["phase"])
                        observed = {**phase, **state}
                        if observed != last:
                            history.append({**observed, "observedSeconds": time.monotonic() - started})
                            input_json("input-observed.json", observed)
                            last = observed
                    elif phase != last:
                        history.append(phase)
                        last = phase
            if acknowledgement.exists() and acknowledgement.read_text() == request_id:
                return
            time.sleep(0.1)
        raise AssertionError(f"Desktop input timed out: {last!r}")
    except Exception as error:
        input_json("input-observed.json", {"id": request_id, "error": str(error)})
        raise
    finally:
        (ARTIFACTS / ("input-" + request_id + ".json")).write_text(json.dumps(history, ensure_ascii=False, indent=2))
        request.unlink(missing_ok=True)


def vscode(*, full):
    workspace = ROOT / "project"
    workspace.mkdir(exist_ok=True)
    (workspace / "example.txt").write_text("Initial document\n")
    for name in ("terminal.txt", "terminal-location.txt", "terminal-context.txt"):
        (workspace / name).unlink(missing_ok=True)
    (workspace / ".vscode").mkdir(exist_ok=True)
    (workspace / ".vscode/settings.json").write_text(json.dumps({
        "workbench.startupEditor": "none", "security.workspace.trust.enabled": False,
        "remote.autoForwardPorts": False, "dev.containers.copyGitConfig": False,
    }))
    if full:
        (workspace / ".devcontainer").mkdir(exist_ok=True)
        (workspace / ".devcontainer/devcontainer.json").write_text(json.dumps({
            "name": "Application workspace", "image": "workspace-fixture:locked",
            "workspaceFolder": "/workspaces/project", "remoteUser": "root",
            "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/project,type=bind",
            "updateRemoteUserUID": False,
        }))
    with sync_playwright() as playwright:
        print("VS Code: opening the configured workspace", flush=True)
        with electron(playwright, "vscode", ["code", "--wait", "--skip-welcome", "--disable-workspace-trust", "--new-window", str(workspace)], 9223) as page:
            phase("workbench")
            page.locator(".monaco-workbench").wait_for()
            if full:
                phase("dev-container")
                page.get_by_role("button", name="Reopen in Container", exact=True).click(timeout=60000)
                print("VS Code: entering the development container", flush=True)
                wait_for(lambda: subprocess.run(
                    ["docker", "ps", "-q", "--filter", f"label=devcontainer.local_folder={workspace}"],
                    capture_output=True, text=True, check=True, timeout=15,
                ).stdout.strip(), "development container", timeout=180)
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    try:
                        page.locator(".monaco-workbench").wait_for(timeout=5000)
                        remote = page.locator('.statusbar-item[id="status.host"]')
                        if "Dev Container: Application workspace" in remote.inner_text(timeout=5000):
                            break
                    except Exception:
                        pass
                    time.sleep(1)
                else:
                    raise AssertionError("VS Code did not connect to its development container")
            # Wait for the Explorer file provider before opening the document.
            phase("editor")
            page.get_by_role("tree", name="Files Explorer").get_by_role("treeitem", name="example.txt", exact=True).dblclick(timeout=90000)
            page.get_by_role("tab", name="example.txt", exact=True).click()
            page.bring_to_front()
            editor_input = page.locator(".monaco-editor:visible").get_by_role("textbox")
            editor_input.focus()
            expect(editor_input).to_be_focused(timeout=30000)
            print("VS Code: document opened; editing with Fcitx", flush=True)
            ui_input({"key": "ctrl-end"}, {"text": "Edited: "}, window="code")
            committed = input_observer(editor_input.evaluate)
            def editor_received(stage):
                state = committed(stage)
                state["document"] = page.locator(".monaco-editor:visible .view-lines").inner_text(timeout=5000).replace("\u00a0", " ")
                if stage == "committed":
                    state["ready"] = state["ready"] and "Edited: 你好" in state["document"]
                return state
            ui_input({"pinyin": "nihao"}, window="code", observe=editor_received)
            ui_input({"key": "ctrl-s"}, window="code")
            wait_for(lambda: "Edited: 你好" in (workspace / "example.txt").read_text(),
                     "saving Chinese text in the editor")
            page.screenshot(path=str(ARTIFACTS / "vscode-editor.png"))
            print("VS Code: executing commands with Chinese input in the integrated terminal", flush=True)
            phase("terminal")
            page.keyboard.press("Control+Shift+Backquote")
            terminal_input = page.get_by_role("textbox", name=re.compile(r"^Terminal \d+,"))
            terminal_input.wait_for()
            terminal_input.focus()
            expect(terminal_input).to_be_focused(timeout=30000)
            terminal_root = "/workspaces/project" if full else str(workspace)
            context_command = "pwd > " + terminal_root + "/terminal-location.txt"
            context_results = {"terminal-location.txt": terminal_root + "\n"}
            if full:
                context_command += "; test -f /.dockerenv && printf container > " + terminal_root + "/terminal-context.txt"
                context_results["terminal-context.txt"] = "container"
            # A completed command confirms that the focused terminal's shell is ready.
            ui_input({"text": context_command + "\n"}, window="code")
            wait_for(lambda: all(
                (workspace / name).exists() and (workspace / name).read_text() == expected
                for name, expected in context_results.items()
            ), "integrated shell ready in " + terminal_root)
            ui_input({"text": "printf '"}, window="code")
            committed = input_observer(terminal_input.evaluate)
            ui_input({"pinyin": "nihao"}, window="code", observe=committed)
            ui_input({"text": "\\n' > " + terminal_root + "/terminal.txt\n"}, window="code")
            terminal = workspace / "terminal.txt"
            wait_for(lambda: terminal.exists() and terminal.read_text() == "你好\n",
                     "Chinese input and command execution in the integrated terminal")
            page.screenshot(path=str(ARTIFACTS / "vscode-terminal.png"))
            ui_input({"text": "exit\n"}, window="code")
            phase("exit-reminder")
            ui_input({"powerGuard": "VS Code"}, window="code")
    return {"workspace": "container" if full else "local", "editor": "你好", "terminal": "你好"}


def firefox(*, full):
    from selenium import webdriver
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.firefox.service import Service
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    profile = Path.home() / ".config/mozilla/firefox/default"
    phase("launch", executable=shutil.which("firefox"), session=os.environ.get("XDG_CURRENT_DESKTOP"))
    with application("firefox", ["firefox", "--no-remote", "--profile", str(profile), "--marionette"]) as process:
        wait_for(lambda: process.poll() is not None or (profile / "lock").is_symlink(), "Firefox profile lock")
        options = Options()
        options.binary_location = shutil.which("firefox")
        service = Service(executable_path=shutil.which("geckodriver"), service_args=["--connect-existing", "--marionette-port", "2828"], log_output=str(ARTIFACTS / "geckodriver.log"))
        browser = webdriver.Firefox(options=options, service=service)
        try:
            phase("page")
            browser.get("http://127.0.0.1:8765/")
            assert "浏览器工作区" in browser.find_element(By.TAG_NAME, "h1").text
            WebDriverWait(browser, 30).until(lambda driver: driver.find_element(By.ID, "ready").text == "Page loaded")
            field = browser.find_element(By.ID, "message")
            field.click()
            committed = input_observer(lambda script: browser.execute_script("return (" + script + ")(arguments[0])", field))
            ui_input({"pinyin": "nihao", "candidateScreenshot": "firefox-candidates"},
                     window="firefox|navigator", observe=committed)
            assert field.get_attribute("value") == "你好", repr(field.get_attribute("value"))
            browser.save_screenshot(str(ARTIFACTS / "firefox.png"))
            ui_input({"powerGuard": "Firefox"}, window="firefox|navigator")
        except Exception:
            with cleanup("Firefox diagnostics"):
                browser.save_screenshot(str(ARTIFACTS / "firefox-failure.png"))
            raise
        finally:
            with cleanup("closing Firefox"):
                browser.quit()
    return {"profile": str(profile), "page": "loaded and rendered", "input": "你好"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", choices=("vscode", "firefox"))
    parser.add_argument("--full", action="store_true", help="exercise the shared development container workflow")
    args = parser.parse_args()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    RUN.update(application=args.application, started=time.time(), result="running")
    phase("starting")
    try:
        result = globals()[args.application](full=args.full)
        RUN.update(result="passed", outcome=result)
    except Exception as error:
        failure(error)
        RUN.update(result="failed", notes=getattr(error, "__notes__", []))
        raise
    finally:
        phase("finished")
        (ARTIFACTS / (args.application + "-result.json")).write_text(json.dumps(RUN, ensure_ascii=False, indent=2) + "\n")
        network_log = ARTIFACTS / (args.application + "-network.json")
        if network_log.exists():
            errors = []
            for line in network_log.read_text(errors="replace").splitlines():
                try:
                    event = json.loads(line.rstrip(",\n"))
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                parameters = event.get("params") or {}
                if parameters.get("net_error", 0) < 0:
                    errors.append({
                        "source": event.get("source"), "type": event.get("type"),
                        "net_error": parameters["net_error"],
                    })
            print(args.application + " network errors:", json.dumps(errors[-30:]), flush=True)
    print(json.dumps({"application": args.application, "result": "passed"}))


if __name__ == "__main__":
    main()
