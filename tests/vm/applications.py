"""Exercise the installed applications inside the logged-in synthetic desktop."""

import argparse
import base64
import hashlib
import hmac
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
import urllib.request
from contextlib import contextmanager

from playwright.sync_api import Error as PlaywrightError, TimeoutError as PlaywrightTimeoutError, expect, sync_playwright


ROOT = Path.home() / "application-workspace"
ARTIFACTS = ROOT / "artifacts"
VAULT_URL = "https://vault.test.nix"
EMAIL = "desktop@example.test"
PASSWORD = "Synthetic-vault-passphrase-2026!"


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


def attach(playwright, port, process):
    def connect():
        if process.poll() not in (None, 0):
            raise AssertionError(f"Application exited with {process.returncode}")
        try:
            return playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{port}", timeout=3000)
        except Exception:
            return None
    return wait_for(connect, "application debugging endpoint")


@contextmanager
def electron(playwright, name, arguments, port):
    network_log = (Path.home() / ".config/Bitwarden/e2e-network.json"
                   if name == "bitwarden" else ARTIFACTS / (name + "-network.json"))
    network_log.parent.mkdir(parents=True, exist_ok=True)
    with application(name, [*arguments, f"--remote-debugging-port={port}",
                            f"--log-net-log={network_log}"]) as process:
        browser = attach(playwright, port, process)
        def application_page():
            for context in browser.contexts:
                for candidate in context.pages:
                    if ("index.html" if name == "bitwarden" else "workbench") in candidate.url:
                        return candidate
            # Synchronous Playwright dispatches page/navigation events during API
            # calls; sleeping while reading cached page lists misses new windows.
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
        # Code's CLI can finish when its window reopens in a container. Track
        # the GUI process so the test service waits for its shutdown as well.
        gui_process = None
        if name == "vscode":
            processes = browser.new_browser_cdp_session().send("SystemInfo.getProcessInfo")
            gui_pid = next(int(item["id"]) for item in processes["processInfo"] if item["type"] == "browser")
            gui_process = os.pidfd_open(gui_pid)
        try:
            yield page
            page.screenshot(path=str(ARTIFACTS / (name + ".png")))
        except Exception:
            with cleanup(name + " diagnostics"):
                (ARTIFACTS / (name + "-failure.txt")).write_text(page.locator("body").inner_text(timeout=5000))
                accessibility = page.locator("body").aria_snapshot(timeout=5000)
                (ARTIFACTS / (name + "-accessibility.txt")).write_text(accessibility)
                print(name + " window at failure:\n" + accessibility, flush=True)
                page.screenshot(path=str(ARTIFACTS / (name + "-failure.png")), timeout=5000)
                if name == "vscode":
                    for log in sorted((Path.home() / ".config/Code/logs").rglob("*.log")):
                        if "remote-containers" in str(log).lower() or "dev containers" in str(log).lower():
                            print(str(log), "\n".join(log.read_text(errors="replace").splitlines()[-100:]), flush=True)
            raise
        finally:
            # Close the window before the process-group fallback. Terminating
            # Electron and all renderers together can itself produce a dump.
            try:
                if not page.is_closed():
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
                    os.close(gui_process)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            if name == "bitwarden" and network_log.exists():
                with cleanup("retaining Bitwarden network log"):
                    shutil.copyfile(network_log, ARTIFACTS / "bitwarden-network.json")


def ui_input(*actions):
    """Ask the VM driver to type through the real keyboard and Fcitx."""
    request_id = str(time.monotonic_ns())
    request = ROOT / "input-request.json"
    pending = ROOT / "input-request.pending"
    acknowledgement = ROOT / "input-complete"
    pending.write_text(json.dumps({"id": request_id, "actions": actions}))
    pending.replace(request)
    try:
        wait_for(lambda: acknowledgement.exists() and acknowledgement.read_text() == request_id,
                 "desktop keyboard input")
    finally:
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
    container_id = None
    try:
        with sync_playwright() as playwright:
            print("VS Code: opening the configured workspace", flush=True)
            with electron(playwright, "vscode", ["code", "--wait", "--skip-welcome", "--disable-workspace-trust", "--new-window", str(workspace)], 9223) as page:
                page.locator(".monaco-workbench").wait_for()
                if full:
                    page.get_by_role("button", name="Reopen in Container", exact=True).click(timeout=60000)
                    print("VS Code: entering the development container", flush=True)
                    container_id = wait_for(lambda: subprocess.run(
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
                page.get_by_role("tree", name="Files Explorer").get_by_role("treeitem", name="example.txt", exact=True).dblclick(timeout=90000)
                page.get_by_role("tab", name="example.txt", exact=True).click()
                page.bring_to_front()
                editor_input = page.locator(".monaco-editor:visible").get_by_role("textbox")
                editor_input.focus()
                expect(editor_input).to_be_focused(timeout=30000)
                print("VS Code: document opened; editing with Fcitx", flush=True)
                ui_input({"key": "ctrl-end"}, {"text": "Edited: "},
                         {"pinyin": "nihao "}, {"key": "ctrl-s"})
                wait_for(lambda: "Edited: 你好" in (workspace / "example.txt").read_text(),
                         "saving Chinese text in the editor")
                page.screenshot(path=str(ARTIFACTS / "vscode-editor.png"))
                print("VS Code: executing commands with Chinese input in the integrated terminal", flush=True)
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
                ui_input({"text": context_command + "\n"})
                wait_for(lambda: all(
                    (workspace / name).exists() and (workspace / name).read_text() == expected
                    for name, expected in context_results.items()
                ), "integrated shell ready in " + terminal_root)
                ui_input({"text": "printf '"}, {"pinyin": "nihao "},
                         {"text": "\\n' > " + terminal_root + "/terminal.txt\n"})
                terminal = workspace / "terminal.txt"
                wait_for(lambda: terminal.exists() and terminal.read_text() == "你好\n",
                         "Chinese input and command execution in the integrated terminal")
                page.screenshot(path=str(ARTIFACTS / "vscode-terminal.png"))
                ui_input({"text": "exit\n"})
                ui_input({"powerGuard": "VS Code"})
    finally:
        if container_id:
            # Complete network teardown before the next application starts.
            with cleanup("stopping development container"):
                subprocess.run(["docker", "stop", container_id], check=True, capture_output=True, timeout=45)
    return {"workspace": "container" if full else "local", "editor": "你好", "terminal": "你好"}


def firefox(*, full):
    from selenium import webdriver
    from selenium.webdriver.firefox.options import Options
    from selenium.webdriver.firefox.service import Service
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    profile = Path.home() / ".config/mozilla/firefox/default"
    with application("firefox", ["firefox", "--no-remote", "--profile", str(profile), "--marionette"]) as process:
        wait_for(lambda: process.poll() is not None or (profile / "lock").is_symlink(), "Firefox profile lock")
        options = Options()
        options.binary_location = shutil.which("firefox")
        service = Service(executable_path=shutil.which("geckodriver"), service_args=["--connect-existing", "--marionette-port", "2828"], log_output=str(ARTIFACTS / "geckodriver.log"))
        browser = webdriver.Firefox(options=options, service=service)
        try:
            browser.get("http://127.0.0.1:8765/")
            assert "浏览器工作区" in browser.find_element(By.TAG_NAME, "h1").text
            WebDriverWait(browser, 30).until(lambda driver: driver.find_element(By.ID, "ready").text == "Page loaded")
            field = browser.find_element(By.ID, "message")
            field.click()
            ui_input({"pinyin": "nihao ", "candidateScreenshot": "firefox-candidates"})
            assert field.get_attribute("value") == "你好", repr(field.get_attribute("value"))
            browser.save_screenshot(str(ARTIFACTS / "firefox.png"))
            ui_input({"powerGuard": "Firefox"})
        except Exception:
            with cleanup("Firefox diagnostics"):
                browser.save_screenshot(str(ARTIFACTS / "firefox-failure.png"))
            raise
        finally:
            with cleanup("closing Firefox"):
                browser.quit()
    return {"profile": str(profile), "page": "loaded and rendered", "input": "你好"}


def register_vault():
    from cryptography.hazmat.primitives import hashes, padding, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
    def b64(value):
        return base64.b64encode(value).decode()
    def encrypt(value, key):
        iv = os.urandom(16)
        padder = padding.PKCS7(128).padder()
        padded = padder.update(value) + padder.finalize()
        cipher = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).encryptor()
        encrypted = cipher.update(padded) + cipher.finalize()
        mac = hmac.new(key[32:], iv + encrypted, hashlib.sha256).digest()
        return "2." + "|".join(map(b64, (iv, encrypted, mac)))
    def post(path, value):
        request = urllib.request.Request(VAULT_URL + path, json.dumps(value).encode(), {"Content-Type": "application/json", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    master = hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), EMAIL.encode(), 600000, 32)
    stretched = b"".join(HKDFExpand(algorithm=hashes.SHA256(), length=32, info=info).derive(master) for info in (b"enc", b"mac"))
    user_key = os.urandom(64)
    asymmetric = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    token = post("/identity/accounts/register/send-verification-email", {"email": EMAIL, "name": "Desktop fixture"})
    post("/identity/accounts/register/finish", {
        "email": EMAIL, "emailVerificationToken": token,
        "masterPasswordHash": b64(hashlib.pbkdf2_hmac("sha256", master, PASSWORD.encode(), 1, 32)),
        "key": encrypt(user_key, stretched), "kdf": 0, "kdfIterations": 600000,
        "keys": {
            "publicKey": b64(asymmetric.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)),
            "encryptedPrivateKey": encrypt(asymmetric.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), user_key),
        },
    })


def bitwarden(*, full):
    if full:
        register_vault()
    with sync_playwright() as playwright:
        with electron(playwright, "bitwarden", ["bitwarden"], 9224) as page:
            if full:
                page.get_by_role("button", name="bitwarden.com", exact=True).click()
                page.get_by_text("self-hosted", exact=True).click()
                page.get_by_label("Server URL").fill(VAULT_URL)
                page.get_by_role("button", name="Save", exact=True).click()
                page.get_by_label("Email address").fill(EMAIL)
                page.get_by_role("button", name="Continue", exact=True).click()
                page.get_by_label(re.compile(r"^Master password\b")).fill(PASSWORD)
                page.get_by_role("button", name="Log in", exact=True).click()
                page.get_by_text("No items in the vault", exact=True).wait_for()
                search = page.get_by_placeholder(re.compile(r"Search vault", re.I))
                search.click()
                ui_input({"pinyin": "nihao "})
                assert search.input_value() == "你好", repr(search.input_value())
            else:
                field = page.get_by_label("Email address")
                field.click()
                ui_input({"pinyin": "nihao "})
                assert field.input_value() == "你好", repr(field.input_value())
            ui_input({"powerGuard": "Bitwarden"})
    return {"flow": "local Vaultwarden login and search" if full else "login screen input", "input": "你好"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", choices=("vscode", "firefox", "bitwarden"))
    parser.add_argument("--full", action="store_true", help="exercise shared container and vault workflows")
    args = parser.parse_args()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    try:
        result = globals()[args.application](full=args.full)
    finally:
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
    (ARTIFACTS / (args.application + "-result.json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"application": args.application, "result": "passed"}))


if __name__ == "__main__":
    main()
