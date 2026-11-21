"""Exercise installed applications inside the logged-in synthetic desktop."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import time

from playwright.sync_api import expect, sync_playwright

from vscode_cdp import (
    cleanup_step,
    managed_process,
    open_integrated_terminal,
    reopen_in_devcontainer,
    vscode_electron_session,
    wait_for,
)


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
    print(
        json.dumps(
            {"application": RUN["application"], "phase": name, "seconds": RUN["seconds"], **details},
            ensure_ascii=False,
        ),
        flush=True,
    )


def failure(error):
    RUN.setdefault(
        "failure",
        {"phase": RUN.get("phase"), "type": type(error).__name__, "message": str(error)},
    )


def input_observer(evaluate, expected="你好"):
    """Observe real IME delivery in a DOM input or a native EditContext."""
    evaluate(
        """element => {
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
    }"""
    )

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
    deadline = started + 165
    history, last = [], None
    input_json(request.name, {"id": request_id, "actions": actions, "window": window})
    try:
        while time.monotonic() < deadline:
            if progress.exists():
                current_phase = json.loads(progress.read_text())
                if current_phase["id"] == request_id:
                    if current_phase.get("error"):
                        raise AssertionError(current_phase["error"])
                    if current_phase["phase"] in ("preedit", "committed"):
                        state = observe(current_phase["phase"])
                        observed = {**current_phase, **state}
                        if observed != last:
                            history.append({**observed, "observedSeconds": time.monotonic() - started})
                            input_json("input-observed.json", observed)
                            last = observed
                    elif current_phase != last:
                        history.append(current_phase)
                        last = current_phase
            if acknowledgement.exists() and acknowledgement.read_text() == request_id:
                return
            time.sleep(0.1)
        raise AssertionError(f"Desktop input timed out: {last!r}")
    except Exception as error:
        input_json("input-observed.json", {"id": request_id, "error": str(error)})
        raise
    finally:
        (ARTIFACTS / ("input-" + request_id + ".json")).write_text(
            json.dumps(history, ensure_ascii=False, indent=2)
        )
        request.unlink(missing_ok=True)


def vscode(*, full):
    workspace = ROOT / "project"
    workspace.mkdir(exist_ok=True)
    (workspace / "example.txt").write_text("Initial document\n")
    for name in ("terminal.txt", "terminal-location.txt", "terminal-context.txt"):
        (workspace / name).unlink(missing_ok=True)
    (workspace / ".vscode").mkdir(exist_ok=True)
    (workspace / ".vscode/settings.json").write_text(
        json.dumps({
            "workbench.startupEditor": "none",
            "security.workspace.trust.enabled": False,
            "remote.autoForwardPorts": False,
            "dev.containers.copyGitConfig": False,
        })
    )
    if full:
        (workspace / ".devcontainer").mkdir(exist_ok=True)
        (workspace / ".devcontainer/devcontainer.json").write_text(
            json.dumps({
                "name": "Application workspace",
                "image": "workspace-fixture:locked",
                "workspaceFolder": "/workspaces/project",
                "remoteUser": "root",
                "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/project,type=bind",
                "updateRemoteUserUID": False,
            })
        )
    with sync_playwright() as playwright:
        print("VS Code: opening the configured workspace", flush=True)
        with vscode_electron_session(
            playwright,
            ["code", "--wait", "--skip-welcome", "--disable-workspace-trust", "--new-window", str(workspace)],
            port=9223,
            artifacts_dir=ARTIFACTS,
            name="vscode",
            state_dict=RUN,
            on_phase=phase,
            on_failure=failure,
        ) as page:
            phase("workbench")
            page.locator(".monaco-workbench").wait_for()
            if full:
                phase("dev-container")
                print("VS Code: entering the development container", flush=True)
                reopen_in_devcontainer(
                    page,
                    workspace,
                    expected_host_label="Dev Container: Application workspace",
                    timeout=180,
                )
            phase("editor")
            page.get_by_role("tree", name="Files Explorer").get_by_role(
                "treeitem", name="example.txt", exact=True
            ).dblclick(timeout=90000)
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
                state["document"] = (
                    page.locator(".monaco-editor:visible .view-lines")
                    .inner_text(timeout=5000)
                    .replace("\u00a0", " ")
                )
                if stage == "committed":
                    state["ready"] = state["ready"] and "Edited: 你好" in state["document"]
                return state

            ui_input({"pinyin": "nihao"}, window="code", observe=editor_received)
            ui_input({"key": "ctrl-s"}, window="code")
            wait_for(
                lambda: "Edited: 你好" in (workspace / "example.txt").read_text(),
                "saving Chinese text in the editor",
            )
            page.screenshot(path=str(ARTIFACTS / "vscode-editor.png"))
            print("VS Code: executing commands with Chinese input in the integrated terminal", flush=True)
            phase("terminal")
            terminal_input = open_integrated_terminal(page, timeout=30000)
            terminal_root = "/workspaces/project" if full else str(workspace)
            context_command = "pwd > " + terminal_root + "/terminal-location.txt"
            context_results = {"terminal-location.txt": terminal_root + "\n"}
            if full:
                context_command += (
                    "; test -f /.dockerenv && printf container > "
                    + terminal_root
                    + "/terminal-context.txt"
                )
                context_results["terminal-context.txt"] = "container"
            ui_input({"text": context_command + "\n"}, window="code")
            wait_for(
                lambda: all(
                    (workspace / name).exists() and (workspace / name).read_text() == expected
                    for name, expected in context_results.items()
                ),
                "integrated shell ready in " + terminal_root,
            )
            ui_input({"text": "printf '"}, window="code")
            committed = input_observer(terminal_input.evaluate)
            ui_input({"pinyin": "nihao"}, window="code", observe=committed)
            ui_input({"text": "\\n' > " + terminal_root + "/terminal.txt\n"}, window="code")
            terminal = workspace / "terminal.txt"
            wait_for(
                lambda: terminal.exists() and terminal.read_text() == "你好\n",
                "Chinese input and command execution in the integrated terminal",
            )
            page.screenshot(path=str(ARTIFACTS / "vscode-terminal.png"))
            ui_input({"text": "exit\n"}, window="code")
            phase("exit-reminder")
            ui_input({"powerGuard": "VS Code"}, window="code")
    return {"workspace": "container" if full else "local", "editor": "你好", "terminal": "你好"}


def firefox(*, full):
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.firefox.service import Service
    from selenium.webdriver.support.ui import WebDriverWait

    del full
    profile = Path.home() / ".config/mozilla/firefox/default"
    phase("launch", executable=shutil.which("firefox"), session=os.environ.get("XDG_CURRENT_DESKTOP"))
    with managed_process(
        ARTIFACTS / "firefox.log",
        ["firefox", "--no-remote", "--profile", str(profile), "--marionette"],
    ) as process:
        wait_for(
            lambda: process.poll() is not None or (profile / "lock").is_symlink(),
            "Firefox profile lock",
        )
        options = Options()
        options.binary_location = shutil.which("firefox")
        service = Service(
            executable_path=shutil.which("geckodriver"),
            service_args=["--connect-existing", "--marionette-port", "2828"],
            log_output=str(ARTIFACTS / "geckodriver.log"),
        )
        browser = webdriver.Firefox(options=options, service=service)
        try:
            phase("page")
            browser.get("http://127.0.0.1:8765/")
            assert "浏览器工作区" in browser.find_element(By.TAG_NAME, "h1").text
            WebDriverWait(browser, 30).until(
                lambda driver: driver.find_element(By.ID, "ready").text == "Page loaded"
            )
            field = browser.find_element(By.ID, "message")
            field.click()
            committed = input_observer(
                lambda script: browser.execute_script("return (" + script + ")(arguments[0])", field)
            )
            ui_input(
                {"pinyin": "nihao", "candidateScreenshot": "firefox-candidates"},
                window="firefox|navigator",
                observe=committed,
            )
            assert field.get_attribute("value") == "你好", repr(field.get_attribute("value"))
            browser.save_screenshot(str(ARTIFACTS / "firefox.png"))
            ui_input({"powerGuard": "Firefox"}, window="firefox|navigator")
        except Exception:
            with cleanup_step("Firefox diagnostics"):
                browser.save_screenshot(str(ARTIFACTS / "firefox-failure.png"))
            raise
        finally:
            with cleanup_step("closing Firefox"):
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
        (ARTIFACTS / (args.application + "-result.json")).write_text(
            json.dumps(RUN, ensure_ascii=False, indent=2) + "\n"
        )
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
                        "source": event.get("source"),
                        "type": event.get("type"),
                        "net_error": parameters["net_error"],
                    })
            print(args.application + " network errors:", json.dumps(errors[-30:]), flush=True)
    print(json.dumps({"application": args.application, "result": "passed"}))


if __name__ == "__main__":
    main()
