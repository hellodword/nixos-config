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
      image = import ../fixtures/applications/container.nix { inherit pkgs; };
      certificates = import (pkgs.path + /nixos/tests/nginx/proxyprotocol/snakeoil-certs.nix);
      python = pkgs.python3.withPackages (p: [
        p.playwright
        p.selenium
        p.cryptography
      ]);
    in
    {
      imports = [
        inputs.impermanence.nixosModules.impermanence
        ../../modules/core/storage.nix
        ../../profiles/laptop/persistence.nix
        ../../modules/core/home.nix
        ../../modules/core/cli.nix
        ../../modules/network/connections.nix
        ../../modules/desktop/workstation.nix
        ../../modules/desktop/apps.nix
        ../../modules/desktop/fonts.nix
        ../../modules/services/containers.nix
      ];
      _module.args.userName = "desktop";
      boot.kernelPackages = pkgs.linuxPackages_6_18;
      virtualisation = {
        memorySize = 6144;
        cores = 2;
        diskSize = 4096;
        qemu.options = [
          "-cpu host"
          "-vga none -device virtio-gpu-pci,xres=1920,yres=1080"
        ];
        emptyDiskImages = [ 8192 ];
        fileSystems."/persist" = {
          device = "/dev/vdb";
          fsType = "ext4";
          autoFormat = true;
          neededForBoot = true;
        };
      };
      services.xserver.resolutions = lib.mkOverride 0 [
        {
          x = 1920;
          y = 1080;
        }
      ];
      users.users.desktop = {
        isNormalUser = true;
        uid = 1000;
        initialPassword = "synthetic-fixture-only";
      };
      site = {
        desktop.enable = true;
        apps.enable = true;
        containers = {
          enable = true;
        };
      };
      services.displayManager.sddm.settings.Users.MaximumUid = 1000;
      hardware.graphics.enable = true;
      environment.variables = {
        WLR_RENDERER = "pixman";
        LIBGL_ALWAYS_SOFTWARE = "1";
      };
      environment.etc = {
        "application-fixtures/container.tar.gz".source = image;
      };
      environment.systemPackages = [
        pkgs.jq
        pkgs.curl
        pkgs.kdotool
        pkgs.geckodriver
        (pkgs.writeShellScriptBin "application-e2e" ''
          exec ${python}/bin/python3 ${./applications.py} "$@"
        '')
      ];
      services.vaultwarden = {
        enable = true;
        config = {
          DOMAIN = "https://vault.test.nix";
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = 8222;
          SIGNUPS_ALLOWED = true;
          SIGNUPS_VERIFY = false;
          WEB_VAULT_ENABLED = false;
        };
      };
      networking.extraHosts = "127.0.0.1 vault.test.nix";
      security.pki.certificateFiles = [ certificates.ca.cert ];
      services.nginx = {
        enable = true;
        virtualHosts."vault.test.nix" = {
          addSSL = true;
          sslCertificate = certificates."*.test.nix".cert;
          sslCertificateKey = certificates."*.test.nix".key;
          locations."/" = {
            proxyPass = "http://127.0.0.1:8222";
            proxyWebsockets = true;
          };
        };
      };
      systemd.services.application-website = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.python3}/bin/python3 ${../fixtures/applications/website.py}";
        };
      };
    };
  nodes = {
    sway = {
      services.displayManager.defaultSession = lib.mkForce "sway";
    };
    i3 = {
      services.displayManager.defaultSession = lib.mkForce "none+i3";
    };
    plasma = {
      services.displayManager.defaultSession = lib.mkForce "plasma";
    };
  };
  testScript = ''
    import base64
    import json
    import runpy
    import shlex
    import tempfile
    import struct
    import threading
    import time
    import traceback
    from datetime import timedelta
    from pathlib import Path

    # Keyboard input and screenshots share the QEMU monitor connection.
    gui_lock = threading.Lock()
    key_delay = timedelta(milliseconds=150)
    gui = runpy.run_path("${./gui.py}")
    visible, login = gui["visible"], gui["login"]

    def user_command(command):
        return "runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemd-run --user --quiet --wait --pipe --collect sh -c " + shlex.quote(command)

    def user(machine, command):
        return machine.succeed(user_command(command))

    def user_status(command):
        return "runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus sh -c " + shlex.quote(command)

    def input_actions(machine, actions):
        with gui_lock:
            for action in actions:
                if "pinyin" in action:
                    user(machine, "fcitx5-remote -s pinyin && fcitx5-remote -o")
                    machine.send_chars(action["pinyin"], delay=key_delay)
                else:
                    user(machine, "fcitx5-remote -c")
                    if "key" in action:
                        machine.send_key(action["key"], delay=key_delay)
                    else:
                        machine.send_chars(action["text"], delay=key_delay)
                machine.sleep(0.2)
            user(machine, "fcitx5-remote -c")

    def exercise_application(machine, application):
        root = "/home/desktop/application-workspace"
        exit_file = root + "/artifacts/" + application + ".exit"
        command = "application-e2e " + application + "; result=$?; printf '%s' \"$result\" > " + exit_file
        user(machine, "systemd-run --user --collect --unit=application-" + application + " sh -c " + shlex.quote(command))
        deadline = time.monotonic() + 600
        handled = None
        while time.monotonic() < deadline:
            status, result = machine.execute("test -f " + exit_file + " && cat " + exit_file)
            if status == 0:
                assert result.strip() == "0", application + " failed: " + result
                return
            active, state = machine.execute(user_status("systemctl --user is-active application-" + application + ".service"))
            if active != 0:
                status, result = machine.execute("test -f " + exit_file + " && cat " + exit_file)
                if status == 0:
                    assert result.strip() == "0", application + " failed: " + result
                    return
                print(machine.execute(user_status("journalctl --user -u application-" + application + ".service -n 60 --no-pager"))[1])
                raise AssertionError(application + " stopped before producing its result: " + state.strip())
            status, request = machine.execute("test -f " + root + "/input-request.json && cat " + root + "/input-request.json")
            if status == 0:
                request = json.loads(request)
                if request["id"] != handled:
                    input_actions(machine, request["actions"])
                    machine.succeed("printf '%s' " + shlex.quote(request["id"]) + " > " + root + "/input-complete")
                    handled = request["id"]
            time.sleep(0.5)
        raise AssertionError(application + " workflow timed out")

    def exercise_launchers(machine, session):
        if session != "KDE":
            with gui_lock:
                machine.send_key("meta_l-d", delay=key_delay)
                visible(machine, r"\bdrun\b")
                machine.send_chars("kitty", delay=key_delay)
                machine.send_key("ret", delay=key_delay)
        else:
            user(machine, "systemd-run --user --collect --unit=kitty-e2e kitty")
        if session == "KDE":
            focused = 'kdotool getwindowclassname "$(kdotool getactivewindow)" | grep -iw kitty'
        else:
            wm = "swaymsg" if session == "sway" else "i3-msg"
            focused = wm + " -t get_tree | jq -e " + shlex.quote('first(.. | objects | select(.focused? == true) | (.app_id // .window_properties.class // "") | ascii_downcase | select(. == "kitty"))')
        machine.wait_until_succeeds(user_command(focused), timeout=60)
        input_actions(machine, [
            {"text": "printf '"}, {"pinyin": "nihao "},
            {"text": "\\n' > ~/application-workspace/terminal.txt\n"},
        ])
        machine.wait_until_succeeds("grep -Fx '你好' /home/desktop/application-workspace/terminal.txt", timeout=30)
        with gui_lock:
            machine.send_chars("exit\n", delay=key_delay)
        if session != "KDE":
            with gui_lock:
                machine.send_key("meta_l-shift-d", delay=key_delay)
                visible(machine, r"\brun\b")
                command = "kitty --title Rofi-command sh -c 'printf launched > ~/application-workspace/rofi-command.txt; sleep 2'"
                # Keep the clipboard owner alive until Rofi consumes the command.
                try:
                    user(machine, "systemd-run --user --collect --unit=rofi-command-clipboard --property=Type=forking desktop-copy " + shlex.quote(command))
                    clipboard = "wl-paste --no-newline" if session == "sway" else "xclip -selection clipboard -o"
                    machine.wait_until_succeeds(
                        user_command('test "$(' + clipboard + ')" = ' + shlex.quote(command)), timeout=10)
                    machine.send_key("ctrl-v", delay=key_delay)
                    visible(machine, r"sleep\s+2")
                    machine.send_key("ctrl-ret", delay=key_delay)
                    machine.wait_until_succeeds("grep -Fx launched /home/desktop/application-workspace/rofi-command.txt", timeout=30)
                finally:
                    user(machine, "systemctl --user stop rofi-command-clipboard.service")

    failures = []
    for machine, session in ((i3, "i3"), (plasma, "KDE"), (sway, "sway")):
        finished = threading.Event()
        ticker = None
        try:
            machine.start()
            login(machine)
            machine.wait_for_unit("home-manager-desktop.service")
            machine.wait_for_unit("docker.service")
            machine.wait_for_unit("vaultwarden.service")
            machine.wait_for_unit("nginx.service")
            machine.wait_until_succeeds(user_command("systemctl --user show-environment | grep '^XDG_CURRENT_DESKTOP=.*" + session + "'"), timeout=180)
            machine.wait_until_succeeds(user_command("busctl --user status org.fcitx.Fcitx5"), timeout=60)
            if session == "KDE":
                machine.wait_until_fails("pgrep -u 1000 -f '^([^ ]*/)?ksplashqml( |$)'", timeout=90)
            user(machine, "fcitx5-remote -c; mkdir -p ~/application-workspace/artifacts")
            user(machine, "busctl --user status org.freedesktop.secrets")
            with tempfile.TemporaryDirectory() as directory:
                frame = Path(directory) / "resolution.png"
                machine.screenshot(str(frame))
                assert struct.unpack(">II", frame.read_bytes()[16:24]) == (1920, 1080), "Application tests require a 1920x1080 desktop"
            # GUI automation is active use. Keep the session awake while the
            # desktop lifecycle suite separately exercises the one-minute lock.
            def activity():
                while not finished.wait(15):
                    with gui_lock:
                        machine.send_key("ctrl", delay=key_delay)
            ticker = threading.Thread(target=activity, daemon=True)
            ticker.start()
            user(machine, "docker load -i /etc/application-fixtures/container.tar.gz")
            for name, action in (
                ("rofi-kitty", lambda: exercise_launchers(machine, session)),
                ("firefox", lambda: exercise_application(machine, "firefox")),
                ("vscode-devcontainer", lambda: exercise_application(machine, "vscode")),
                ("bitwarden", lambda: exercise_application(machine, "bitwarden")),
            ):
                try:
                    with subtest(session + ": " + name):
                        action()
                        with gui_lock:
                            machine.screenshot(machine.name + "-" + name)
                except Exception as error:
                    failures.append((session, name, str(error)))
                    traceback.print_exc()
                    print(machine.execute("journalctl -b -u nginx -u vaultwarden -n 40 --no-pager")[1])
                    print(machine.execute("journalctl _UID=1000 -n 50 --no-pager")[1])
                    print(machine.execute("tail -n 50 /home/desktop/application-workspace/artifacts/*.log /home/desktop/application-workspace/artifacts/*-failure.txt")[1])
                    application = "vscode" if name == "vscode-devcontainer" else name
                    frame_path = "/home/desktop/application-workspace/artifacts/" + application + "-failure.png"
                    status, frame = machine.execute("test -f " + frame_path + " && base64 -w0 " + frame_path)
                    if status != 0:
                        with tempfile.TemporaryDirectory() as directory:
                            path = Path(directory) / "failure.png"
                            with gui_lock:
                                machine.screenshot(str(path))
                            frame = base64.b64encode(path.read_bytes()).decode()
                    print("APPLICATION_FRAME_" + machine.name + "_" + name + "=" + frame.strip())
                    break
                finally:
                    machine.execute("pkill -u 1000 -x rofi")
        except Exception as error:
            failures.append((session, "session", str(error)))
            traceback.print_exc()
        finally:
            finished.set()
            if ticker is not None:
                ticker.join(timeout=5)
            try:
                machine.copy_from_machine("/home/desktop/application-workspace/artifacts", "applications-" + machine.name)
            except Exception as error:
                failures.append((session, "evidence", str(error)))
            finally:
                machine.shutdown()
        if failures:
            break
    assert not failures, failures
  '';
}
