{ inputs }:
{ lib, ... }:
{
  name = "desktop-application-workflows";
  enableOCR = true;
  globalTimeout = 1800;
  qemu.forceAccel = true;
  node.pkgsReadOnly = false;
  node.specialArgs = { inherit inputs; };
  defaults =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (p: [
        p.playwright
        p.selenium
      ]);
    in
    {
      imports = [
        (import ./background.nix { scenario = "applications"; })
        ../fixtures/vm-sops.nix
        ../../profiles/laptop/persistence.nix
        ../../modules/core/home.nix
        ../../modules/core/cli.nix
        ../../modules/network/connections.nix
        ../../modules/desktop/workstation.nix
        ../../modules/desktop/apps.nix
        ../../modules/desktop/fonts.nix
      ];
      _module.args.userName = "desktop";
      time.timeZone = "America/New_York";
      boot.kernelPackages = pkgs.linuxPackages_6_18;
      virtualisation = {
        memorySize = 3072;
        cores = 2;
        diskSize = 4096;
        qemu.options = [
          "-cpu host"
          "-vga none -device virtio-gpu-pci,xres=1920,yres=1080"
        ];
        emptyDiskImages = [ 2048 ];
        fileSystems."/persist" = {
          device = "/dev/vdb";
          fsType = "ext4";
          autoFormat = true;
          neededForBoot = true;
        };
      };
      home-manager.users.desktop.home.stateVersion = "22.11";
      users.users.desktop = {
        isNormalUser = true;
        uid = 1000;
        password = "synthetic-fixture-only";
      };
      site = {
        desktop.enable = true;
        apps.enable = true;
      };
      services.displayManager.sddm.settings.Users.MaximumUid = 1000;
      hardware.graphics.enable = true;
      environment.variables = {
        WLR_RENDERER = "pixman";
        LIBGL_ALWAYS_SOFTWARE = "1";
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.kdotool
        pkgs.geckodriver
        (pkgs.writeShellScriptBin "application-e2e" ''
          export PYTHONPATH="${inputs.infra.lib.testing.testingDir}''${PYTHONPATH:+:$PYTHONPATH}"
          exec ${python}/bin/python3 ${./applications.py} "$@"
        '')
      ];
      systemd.services.application-website = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.python3}/bin/python3 ${../fixtures/applications/website.py}";
        };
      };
    };
  nodes = {
    sway =
      { pkgs, ... }:
      let
        image = import ../fixtures/applications/container.nix { inherit pkgs; };
      in
      {
        imports = [ ../../modules/services/containers.nix ];
        services.displayManager.defaultSession = lib.mkForce "sway";
        virtualisation = {
          memorySize = lib.mkForce 6144;
          emptyDiskImages = lib.mkForce [ 8192 ];
        };
        site.containers.enable = true;
        environment.etc."application-fixtures/container.tar.gz".source = image;
      };
    plasma = {
      services.displayManager.defaultSession = lib.mkForce "plasma";
    };
  };
  testScript = ''
    import json
    import re
    import runpy
    import shlex
    import tempfile
    import struct
    import sys
    import time
    import traceback
    import uuid
    from datetime import timedelta
    from pathlib import Path


    key_delay = timedelta(milliseconds=150)
    gui = runpy.run_path("${inputs.infra.lib.testing.guiPy}")
    runtime = runpy.run_path("${inputs.infra.lib.testing.runtimePy}")
    visible, login = gui["visible"], gui["login"]
    power_menu = runpy.run_path("${./power_menu.py}")

    def user_command(command, timeout=60):
        return ("runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemd-run --user --quiet --wait --pipe --collect "
                + f"--property=RuntimeMaxSec={timeout}s --property=TimeoutStopSec=5s sh -c " + shlex.quote(command))

    def user(machine, command, timeout=60):
        return machine.succeed(user_command(command, timeout), timeout=timedelta(seconds=timeout + 10))

    def user_status(command):
        return "runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus sh -c " + shlex.quote(command)

    def input_json(machine, name, value):
        path = "/home/desktop/application-workspace/" + name
        machine.succeed("printf '%s' " + shlex.quote(json.dumps(value, ensure_ascii=False))
                        + " > " + path + ".pending && mv " + path + ".pending " + path, timeout=10)

    def input_actions(machine, actions, window, request_id=None, observe=None):
        started = time.monotonic()
        deadline = started + 90
        events = []
        phase = "focus"
        last = None

        def event(stage, **details):
            nonlocal phase
            phase = stage
            record = {"id": request_id, "phase": stage, "seconds": time.monotonic() - started, **details}
            events.append(record)
            if request_id:
                input_json(machine, "input-progress.json", record)

        def received(index, stage):
            nonlocal last
            event(stage, action=index)
            while time.monotonic() < deadline:
                if observe:
                    last = observe(stage)
                else:
                    status, text = machine.execute(
                        "cat /home/desktop/application-workspace/input-observed.json", timeout=gui["remaining"](deadline))
                    last = json.loads(text) if status == 0 else None
                    if last and last.get("id") == request_id and last.get("error"):
                        raise AssertionError(last["error"])
                    if last and (last.get("id"), last.get("action"), last.get("phase")) != (request_id, index, stage):
                        last = None
                if last and last.get("ready"):
                    event(stage + "-received", observed=last)
                    return
                time.sleep(0.1)
            raise AssertionError(f"Input {stage} timed out: {last!r}")

        with machine.input_lock:
            try:
                with machine.action(deadline):
                    while time.monotonic() < deadline:
                        focused: str = gui["focused_window"](machine, user_command, deadline)
                        last = focused
                        if re.search(window, focused, re.I):
                            break
                        time.sleep(0.1)
                    else:
                        raise AssertionError(f"Window focus timed out: {last!r}")
                    event("focused", window=last)
                    for index, action in enumerate(actions):
                        if "powerGuard" in action:
                            power_menu["blocked"](machine, user, visible, "Log out", action["powerGuard"])
                        elif "pinyin" in action:
                            event("activating", action=index)
                            state = gui["input_method"](machine, user_command, True, deadline)
                            event("activated", **state)
                            machine.send_chars(action["pinyin"], delay=key_delay)
                            if observe is None:
                                received(index, "preedit")
                            if "candidateScreenshot" in action:
                                machine.screenshot(machine.name + "-" + action["candidateScreenshot"])
                            machine.send_chars(" ", delay=key_delay)
                            received(index, "committed")
                            event("deactivating")
                            state = gui["input_method"](machine, user_command, False, deadline)
                            event("deactivated", **state)
                        else:
                            event("english", action=index)
                            gui["input_method"](machine, user_command, False, deadline)
                            if "key" in action:
                                machine.send_key(action["key"], delay=key_delay)
                            else:
                                machine.send_chars(action["text"], delay=key_delay)
                    event("complete")
                    return True
            except Exception as error:
                failed_phase = phase
                details = {"observed": last}
                with machine.action(time.monotonic() + 60):
                    runtime["collect_failure"](error, [
                        (machine, "input-context", user_status("busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 DebugInfo")),
                        (machine, "input-journal", "journalctl _UID=1000 -n 60 --no-pager"),
                    ], [machine])
                try:
                    event("error", error=f"Input {failed_phase}: {error}", **details)
                except Exception as reporting_error:
                    error.add_note("Publishing input failure: " + str(reporting_error))
                    raise error
                if request_id:
                    return False
                raise
            finally:
                destination = Path(machine.out_dir) / (machine.name + "-input-" + (request_id or str(time.monotonic_ns())) + ".json")
                destination.write_text(json.dumps(events, ensure_ascii=False, indent=2))

    cleanup_failures: dict[str, str] = {}

    def exercise_application(machine, application, full=False):
        root = "/home/desktop/application-workspace"
        execution = application + "-" + uuid.uuid4().hex
        exit_file = root + "/artifacts/" + execution + ".json"
        unit = "application-" + execution
        started = machine.succeed("date +%s", timeout=10).strip()
        user(machine, "rm -f " + " ".join(root + "/input-" + name + ".json" for name in ("request", "observed", "progress")) + " " + root + "/input-complete")
        command = "application-e2e " + application + (" --full" if full else "") + "; result=$?; printf "
        command += shlex.quote('{"id":"' + execution + '","status":%s}\n') + ' "$result" > ' + exit_file + ".pending; mv " + exit_file + ".pending " + exit_file

        def completed(result):
            receipt = json.loads(result)
            assert receipt["id"] == execution, "Application result belongs to another execution: " + result
            if receipt["status"]:
                status, state = machine.execute("cat " + root + "/artifacts/" + application + "-state.json", timeout=10)
                detail = json.loads(state).get("failure") if status == 0 else None
                raise AssertionError(application + " failed: " + json.dumps(detail or receipt, ensure_ascii=False))

        try:
            user(machine, "systemd-run --user --collect --property=RemainAfterExit=yes --property=TimeoutStopSec=15s --property=RuntimeMaxSec=660s --unit=" + unit + " sh -c " + shlex.quote(command))
            deadline = time.monotonic() + 600
            handled = None
            while time.monotonic() < deadline:
                status, result = machine.execute("test -f " + exit_file + " && cat " + exit_file, timeout=min(30, max(1, deadline - time.monotonic())))
                if status == 0:
                    completed(result)
                    return
                active, state = machine.execute(user_status("systemctl --user is-active " + unit + ".service"), timeout=min(30, max(1, deadline - time.monotonic())))
                if active != 0:
                    status, result = machine.execute("test -f " + exit_file + " && cat " + exit_file, timeout=10)
                    if status == 0:
                        completed(result)
                        return
                    raise AssertionError(application + " stopped before producing its result: " + state.strip())
                status, request = machine.execute("test -f " + root + "/input-request.json && cat " + root + "/input-request.json", timeout=min(30, max(1, deadline - time.monotonic())))
                if status == 0:
                    request = json.loads(request)
                    if request["id"] != handled:
                        if input_actions(machine, request["actions"], request["window"], request_id=request["id"]):
                            machine.succeed("printf '%s' " + shlex.quote(request["id"]) + " > " + root + "/input-complete.pending; mv " + root + "/input-complete.pending " + root + "/input-complete", timeout=10)
                        handled = request["id"]
                time.sleep(0.5)
            raise AssertionError(application + " workflow timed out")
        except Exception as error:
            try:
                status, state = machine.execute("cat " + root + "/artifacts/" + application + "-state.json", timeout=10)
                if status == 0:
                    error.add_note("Application state: " + state)
                    print(state)
            except Exception as capture_error:
                error.add_note("Reading application state: " + str(capture_error))
            # Electron can move into a desktop scope; coredumps use a system service.
            runtime["collect_failure"](error, [
                (machine, execution + "-journal", "journalctl -b --no-pager -o short-precise --since=@" + started + " _UID=1000 + COREDUMP_UID=1000"),
                (machine, execution + "-core", "coredumpctl --no-pager --since=@" + started + " info COREDUMP_UID=1000"),
                (machine, execution + "-kernel", "journalctl -b -k --no-pager --since=@" + started),
                (machine, execution + "-processes", "ps -u desktop -o pid,ppid,stat,etimes,cgroup,args"),
            ])
            try:
                machine.screenshot(machine.name + "-" + execution + "-failure", timeout=20)
            except Exception as capture_error:
                error.add_note("Application screenshot: " + str(capture_error))
            raise
        finally:
            original = sys.exception()
            try:
                print("Cleaning application execution " + execution, flush=True)
                units = [unit + ".service"]
                status, state = machine.execute("cat " + root + "/artifacts/" + application + "-state.json", timeout=10)
                gui_unit = json.loads(state).get("guiUnit") if status == 0 else None
                if gui_unit and gui_unit not in units:
                    units.insert(0, gui_unit)
                for name in units:
                    status, loaded = machine.execute(user_status("systemctl --user show " + shlex.quote(name) + " -p LoadState --value"), timeout=10)
                    if loaded.strip() != "not-found":
                        assert status == 0, "Reading application unit: " + loaded
                        user(machine, "systemctl --user stop " + shlex.quote(name), timeout=30)
                if full:
                    # The container may exist even when Code never reported attachment.
                    label = shlex.quote("label=devcontainer.local_folder=" + root + "/project")
                    containers = user(machine, "docker ps -q --filter " + label, timeout=10).split()
                    if containers:
                        user(machine, "docker stop " + " ".join(containers), timeout=45)
                    assert not user(machine, "docker ps -q --filter " + label, timeout=10).strip(), "Development container is still running"
            except Exception as error:
                cleanup_failures[machine.name] = str(error)
                if original is not None:
                    original.add_note("Application cleanup: " + str(error))
                else:
                    raise

    def exercise_launchers(machine, session):
        if session != "KDE":
            with machine.input_lock:
                for query in ("incognito", "private"):
                    machine.send_key("meta_l-d", delay=key_delay)
                    power_menu["ready"](machine, visible, "drun")
                    machine.send_chars(query, delay=key_delay)
                    power_menu["ready"](machine, visible, "drun", typed=query, unique=True)
                    machine.send_key("esc", delay=key_delay)
                    machine.wait_until_fails(r"pgrep -u 1000 -f '^([^ ]*/)?\.?rofi(-wrapped)?( |$)'", timeout=15)
                machine.send_key("meta_l-d", delay=key_delay)
                power_menu["ready"](machine, visible, "drun")
                machine.send_chars("kitty", delay=key_delay)
                power_menu["ready"](machine, visible, "drun", typed="kitty", unique=True)
                machine.send_key("ret", delay=key_delay)
        else:
            user(machine, "systemd-run --user --collect --unit=kitty-e2e kitty")
        if session == "KDE":
            focused = 'kdotool getwindowclassname "$(kdotool getactivewindow)" | grep -iw kitty'
        else:
            focused = "swaymsg -t get_tree | jq -e " + shlex.quote('first(.. | objects | select(.focused? == true) | (.app_id // .window_properties.class // "") | ascii_downcase | select(. == "kitty"))')
        machine.wait_until_succeeds(user_command(focused), timeout=60)
        machine.screenshot(machine.name + "-kitty-prompt")
        input_actions(machine, [{"text": "printf ready > ~/application-workspace/terminal-ready; IFS= read -r -n 2 value; printf '%s\\n' \"$value\" > ~/application-workspace/terminal.txt\n"}], "kitty")
        machine.wait_until_succeeds("test -f /home/desktop/application-workspace/terminal-ready", timeout=30)
        def terminal_received(stage):
            status, text = machine.execute("cat /home/desktop/application-workspace/terminal.txt", timeout=10)
            return {"ready": status == 0 and text == "你好\n", "text": text}
        input_actions(machine, [{"pinyin": "nihao"}], "kitty", observe=terminal_received)
        machine.wait_until_succeeds("grep -Fx '你好' /home/desktop/application-workspace/terminal.txt", timeout=30)
        with machine.input_lock:
            machine.send_chars("exit\n", delay=key_delay)
        if session != "KDE":
            with machine.input_lock:
                machine.send_key("meta_l-shift-d", delay=key_delay)
                power_menu["ready"](machine, visible, "run")
                user(machine, "printf '%s\\n' 'printf launched > ~/application-workspace/rofi-command.txt; sleep 2' > /tmp/rofi-launch")
                # Keep the whole command visible in Rofi's input row.
                command = "kitty --title Rofi-command sh /tmp/rofi-launch"
                # Keep the clipboard owner alive until Rofi consumes the command.
                try:
                    user(machine, "systemd-run --user --collect --unit=rofi-command-clipboard --property=Type=forking desktop-copy " + shlex.quote(command))
                    machine.wait_until_succeeds(
                        user_command('test "$(wl-paste --no-newline)" = ' + shlex.quote(command)), timeout=10)
                    machine.send_key("ctrl-v", delay=key_delay)
                    visible(machine, r"run:?\s+" + re.escape(command), region=power_menu["REGION"])
                    machine.send_key("ctrl-ret", delay=key_delay)
                    machine.wait_until_succeeds("grep -Fx launched /home/desktop/application-workspace/rofi-command.txt", timeout=30)
                finally:
                    user(machine, "systemctl --user stop rofi-command-clipboard.service")

    def exercise_firejail(machine):
        machine.succeed("printf firejail-persist-canary > /persist/firejail-canary.txt && chmod 0644 /persist/firejail-canary.txt")
        user(machine, "test -r /persist/firejail-canary.txt")
        for wrapped in ("firefox", "feh"):
            user(machine, f"grep -F '/run/wrappers/bin/firejail' \"$(command -v {wrapped})\"")
        user(machine, "feh --version >/dev/null")
        user(
            machine,
            "mkdir -p ~/.gemini/antigravity-cli/brain/session && "
            "printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' | "
            "base64 -d | tee ~/.gemini/antigravity-cli/brain/session/sample.png > ~/.gemini/antigravity-cli/outside.png && "
            "feh --list ~/.gemini/antigravity-cli/brain/session/sample.png >/dev/null && "
            "! feh --list ~/.gemini/antigravity-cli/outside.png >/dev/null 2>&1",
        )
        user(
            machine,
            "profile=$(sed -n 's/.*\\(--profile=[^ ]*\\).*/\\1/p' \"$(command -v firefox)\") && "
            "test -n \"$profile\" && /run/wrappers/bin/firejail --quiet \"$profile\" -- test ! -e /persist/firejail-canary.txt",
        )

    failures = []
    outcomes = []
    for machine, session in ((plasma, "KDE"), (sway, "sway")):
        machine = gui["Desktop"](machine)
        try:
            machine.start()
            login(machine)
            machine.wait_for_unit("home-manager-desktop.service")
            machine.succeed(
                "test \"$(cat /proc/sys/kernel/io_uring_disabled)\" = 1 && "
                "test \"$(cat /run/secrets/vm-smoke)\" = synthetic-sops-ready && "
                "/run/wrappers/bin/sudo --version | grep -qi sudo-rs"
            )
            if session == "sway":
                machine.wait_for_unit("docker.service")
            else:
                machine.fail("systemctl is-enabled docker.service")
            gui["wait_for_session"](machine, session, user_command)
            if session == "KDE":
                machine.wait_until_fails("pgrep -u 1000 -f '^([^ ]*/)?ksplashqml( |$)'", timeout=90)
            user(machine, "fcitx5-remote -c; mkdir -p ~/application-workspace/artifacts")
            user(machine, "busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/classicui 'a{sv}' 2 Theme s catppuccin-mocha-pink DarkTheme s catppuccin-mocha-pink")
            user(machine, "busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Save")
            machine.wait_until_succeeds(user_command("busctl --user status org.freedesktop.secrets"), timeout=60)
            with tempfile.TemporaryDirectory() as directory:
                frame = Path(directory) / "resolution.png"
                machine.screenshot(str(frame))
                assert struct.unpack(">II", frame.read_bytes()[16:24]) == (1920, 1080), "Application tests require a 1920x1080 desktop"
            # Hold native idle inhibition while keyboard workflows are active.
            machine.inhibit_idle()
            if session == "sway":
                user(machine, "docker load -i /etc/application-fixtures/container.tar.gz", timeout=300)
            blocked = None
            for name, action in (
                ("firejail", lambda: exercise_firejail(machine)),
                ("rofi-kitty", lambda: exercise_launchers(machine, session)),
                ("firefox", lambda: exercise_application(machine, "firefox")),
                ("vscode", lambda: exercise_application(machine, "vscode", full=session == "sway")),
            ):
                if blocked:
                    outcomes.append({"session": session, "application": name, "result": "not-run", "reason": blocked})
                    continue
                try:
                    with subtest(session + ": " + name):
                        action()
                        machine.screenshot(machine.name + "-" + name)
                    outcomes.append({"session": session, "application": name, "result": "passed"})
                except Exception as error:
                    failures.append((session, name, str(error)))
                    outcomes.append({"session": session, "application": name, "result": "failed", "error": str(error), "notes": getattr(error, "__notes__", [])})
                    traceback.print_exc()
                    if name == "rofi-kitty":
                        runtime["collect_failure"](error, [
                            (machine, "launchers", "journalctl -b _UID=1000 -n 100 --no-pager"),
                        ], [machine])
                        blocked = "Desktop launcher setup failed: " + str(error)
                    elif machine.name in cleanup_failures:
                        blocked = "Application cleanup failed: " + cleanup_failures[machine.name]
                finally:
                    machine.execute("pkill -u 1000 -x rofi", timeout=10)
        except Exception as error:
            failures.append((session, "session", str(error)))
            outcomes.append({"session": session, "result": "failed", "error": str(error), "remainingApplications": "not-run"})
            traceback.print_exc()
            runtime["collect_failure"](error, [
                (machine, "login", "journalctl -b -u display-manager -n 60 --no-pager"),
            ], [machine])
        finally:
            try:
                machine.resume_idle()
            except Exception as error:
                failures.append((session, "idle control", str(error)))
            try:
                machine.copy_from_machine("/home/desktop/application-workspace/artifacts", "applications-" + machine.name)
            except Exception as error:
                failures.append((session, "evidence", str(error)))
            finally:
                try:
                    machine.shutdown()
                except Exception as error:
                    failures.append((session, "shutdown", str(error)))
        (Path(machine.out_dir) / "application-results.json").write_text(json.dumps(outcomes, ensure_ascii=False, indent=2))
    print(json.dumps(outcomes, ensure_ascii=False), flush=True)
    assert not failures, failures
  '';
}
