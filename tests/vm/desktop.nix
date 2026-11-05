{ inputs }:
{ pkgs, lib, ... }:
let
  identityDirectory = "/home/desktop/.local/state/identity-fixture";
  identitySource = "/persist/home/desktop/.local/state/identity-fixture/identity.yaml";
  identityFixture = "${
    pkgs.python3.withPackages (ps: [ ps.pyyaml ])
  }/bin/python3 ${../fixtures/gpg_identity.py}";

in
{
  name = "native-desktop-sessions";
  enableOCR = true;
  globalTimeout = 900;
  qemu.forceAccel = true;
  node.pkgsReadOnly = false;
  node.specialArgs = { inherit inputs; };
  defaults = {
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
      ../../modules/services/android.nix
      ../../modules/desktop/productivity.nix
    ];
    _module.args = {
      userName = "desktop";
    };
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      qemu.options = [ "-vga none -device virtio-gpu-pci" ];
      # A real mount lets the status bar report persistence usage and gives the
      # persistence checks a separate disk that survives guest reboots.
      emptyDiskImages = [ 512 ];
      fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };
    users.users.desktop = {
      isNormalUser = true;
      uid = 1000;
      initialPassword = "synthetic-fixture-only";
    };
    site.desktop.enable = true;
    services.safeeyes.enable = true;
    hardware.graphics.enable = true;
    services.displayManager.sddm.settings.Users.MaximumUid = 1000;
    environment.variables = {
      WLR_RENDERER = "pixman";
      LIBGL_ALWAYS_SOFTWARE = "1";
    };
    environment.systemPackages = [
      pkgs.jq
      pkgs.libsecret
      pkgs.glib
      pkgs.xdg-utils
      pkgs.procps
      pkgs.pipewire
      pkgs.kdePackages.kconfig
      pkgs.kdePackages.kdialog
    ];
  };
  nodes = {
    sway = {
      services.displayManager.defaultSession = lib.mkForce "sway";
      environment.variables = {
        WLR_BACKENDS = "drm,libinput,headless";
        WLR_HEADLESS_OUTPUTS = "0";
      };
    };
    i3 = {
      services.displayManager.defaultSession = lib.mkForce "none+i3";
      # qemu-vm otherwise injects 1024x768 as an Xorg user-preferred mode.
      # Exercise an unknown monitor's EDID preference, with no saved override.
      services.xserver.resolutions = lib.mkOverride 0 [ ];
    };
    plasma = {
      services.displayManager.defaultSession = lib.mkForce "plasma";
      boot.kernelModules = [ "mac80211_hwsim" ];
      # qemu-vm disables wireless with mkVMOverride. NetworkManager uses the
      # real supplicant D-Bus backend against the simulated radio driver.
      networking.wireless.enable = lib.mkOverride 0 true;
      site.cli = {
        enable = true;
        identityFile = identitySource;
      };
      systemd.services.site-identity.unitConfig.ConditionPathExists = identitySource;
      environment.persistence."/persist".users.desktop.directories = [
        ".local/state/identity-fixture"
      ];
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
      };
      site.connections.enable = true;
      networking.networkmanager = {
        unmanaged = [ "interface-name:eth*" ];
        ensureProfiles = {
          environmentFiles = [ "/etc/fixture-wifi-env" ];
          profiles.baseline = {
            connection = {
              id = "synthetic-baseline";
              uuid = "cb4a1532-b748-46ad-8844-26c2fac8cb08";
              type = "wifi";
            };
            wifi.ssid = "$WIFI_SSID";
            wifi-security = {
              key-mgmt = "wpa-psk";
              psk = "$WIFI_PASSWORD";
            };
            ipv4.method = "auto";
            ipv6.method = "auto";
          };
        };
      };
      environment.etc = {
        fixture-wifi-env.text = ''
          WIFI_SSID=synthetic-baseline
          WIFI_PASSWORD=synthetic-passphrase
        '';
      };
    };
  };
  testScript = ''
    import re
    import json
    import shlex
    import base64
    import runpy
    import tempfile
    from datetime import timedelta
    import traceback
    from pathlib import Path

    def user_command(command):
        prefix = "runuser -u desktop -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
        # GUI tools need the environment imported into the user manager,
        # including DISPLAY/I3SOCK/SWAYSOCK from the real login session.
        return prefix + "systemd-run --user --quiet --wait --pipe --collect --property=RuntimeMaxSec=60s sh -c " + shlex.quote(command)

    def user(machine, command, fail=False):
        # These commands represent an active desktop user. Backend execution
        # alone does not reset the compositor's real one-minute idle timer.
        machine.send_key("ctrl")
        return (machine.fail if fail else machine.succeed)(user_command(command))

    def identity_fixture(machine, operation):
        return user(machine, "${identityFixture} " + operation + " --directory ${identityDirectory}")

    def identity_ready(machine):
        machine.wait_until_succeeds(user_command("${identityFixture} verify --directory ${identityDirectory}"), timeout=30)
        for purpose in ("github", "local"):
            assert user(machine, "ssh fixture-" + purpose + " whoami").strip() == "desktop"

    def preferred_layout(machine):
        try:
            machine.wait_until_succeeds(user_command("xrandr --query | grep -E ' connected[^[:cntrl:]]*1280x800\\+0\\+0'"), timeout=30)
        except Exception:
            print(user(machine, "xrandr --query"))
            print(user(machine, "journalctl --user -u autorandr.service -n 60 --no-pager"))
            raise

    def reconnect_i3_display(machine, output):
        connector = machine.succeed("readlink -f /sys/class/drm/card*-" + shlex.quote(output) + "/status").strip()
        machine.succeed("printf off > " + shlex.quote(connector))
        machine.wait_until_succeeds(user_command("xrandr --query | grep -E " + shlex.quote("^" + re.escape(output) + " disconnected")), timeout=30)
        machine.succeed("printf detect > " + shlex.quote(connector))

    def process(name):
        # Match argv[0], including Nix wrappers. Idle managers also contain
        # their lock command in later arguments while the screen is unlocked.
        return "pgrep -u 1000 -f " + shlex.quote(r"^([^ ]*/)?\.?" + re.escape(name) + r"(-wrapped)?( |$)")

    gui = runpy.run_path("${./gui.py}")
    visible, login = gui["visible"], gui["login"]

    def unlock(machine, session):
        locker = {"sway": "swaylock", "i3": "i3lock", "KDE": "kscreenlocker_greet"}[session]
        if machine.execute(process(locker))[0] == 0:
            if session == "KDE":
                machine.send_key("ctrl")
                visible(machine, "Switch User")
            else:
                machine.sleep(1)
            # QEMU holds each key for 100 ms. Let the clear chord release
            # before entering the password through the greeter's keyboard.
            machine.send_key("ctrl-u", delay=timedelta(milliseconds=150))
            machine.send_chars("synthetic-fixture-only", delay=timedelta(milliseconds=150))
            machine.send_key("ret")
            machine.wait_until_fails(process(locker), timeout=30)

    def stop_session(machine, compositor):
        machine.succeed("systemctl stop display-manager.service")
        try:
            for unit in ("graphical-session.target", "desktop-health.timer", "site-sway.target", "site-i3.target"):
                machine.wait_until_fails(user_command("systemctl --user is-active " + unit), timeout=60)
            # A late notification must not restart a notifier after logout.
            user(machine, "notify-send 'Session has ended'", True)
            for name in (compositor, "waybar", "mako", "dunst", "fcitx5"):
                machine.wait_until_fails(process(name), timeout=60)
        except Exception:
            for command in ("loginctl list-sessions", "ps -u 1000 -o pid,ppid,comm",
                            user_command("systemctl --user status 'site-session-watch@*.service' graphical-session.target"),
                            "journalctl _UID=1000 -n 80 --no-pager"):
                print(command, machine.execute(command)[1])
            raise

    def login_session(machine, session, compositor):
        login(machine)
        machine.wait_until_succeeds(process(compositor), timeout=180)
        machine.wait_until_succeeds(user_command("systemctl --user is-active graphical-session.target desktop-health.timer"), timeout=60)
        # A compositor process exists before its config imports the session
        # environment. Wait for that explicit readiness boundary.
        machine.wait_until_succeeds(user_command("systemctl --user show-environment | grep '^XDG_CURRENT_DESKTOP=.*" + session + "'"), timeout=60)
        machine.wait_until_succeeds(user_command("busctl --user status org.fcitx.Fcitx5"), timeout=60)

    def exercise_session(machine, session, compositor):
        machine.wait_for_unit("persist.mount")
        login_session(machine, session, compositor)
        unlock(machine, session)
        machine.wait_until_succeeds(user_command("printf 'wallet-fixture' | timeout 20 secret-tool store --label=Desktop-test purpose desktop-test"), timeout=60)
        assert user(machine, "timeout 15 secret-tool lookup purpose desktop-test").strip() == "wallet-fixture"
        user(machine, "gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Properties.Get org.freedesktop.portal.Settings version")
        assert user(machine, "xdg-mime query default inode/directory").strip() == "org.kde.dolphin.desktop"
        # PipeWire may be socket activated on a VM with no sound hardware.
        user(machine, "timeout 20 pw-cli info 0")
        machine.wait_until_succeeds(user_command("systemctl --user is-active pipewire.service wireplumber.service"), timeout=60)
        # Launch through the actual imported systemd user environment.
        user(machine, "systemd-run --user --collect --unit=desktop-fixture kitty --title Desktop-fixture sh -c 'printf \"Native desktop / 原生桌面\\n\"; sleep 600'")
        machine.wait_until_succeeds(user_command("systemctl --user is-active desktop-fixture.service"))
        machine.wait_until_succeeds(process("kitty"))
        if session == "KDE":
            # The shell and user services can be ready while the software-
            # rendered startup splash still covers application windows.
            visible(machine, "Native desktop", timeout=180)
        if session == "sway":
            user(machine, "systemctl --user is-active site-sway.target waybar.service mako.service")
            user(machine, "systemctl --user is-active site-i3.target", True)
            machine.wait_until_succeeds(user_command("swaymsg -t get_tree | grep Desktop-fixture"))
        elif session == "i3":
            user(machine, "systemctl --user is-active site-i3.target dunst.service autorandr.service")
            user(machine, "systemctl --user is-active site-sway.target", True)
            # Unknown monitors use the EDID preference: QEMU offers 5120x2160
            # but marks 1280x800 as preferred.
            modes = user(machine, "xrandr --query")
            assert re.search(r"^\s+1280x800\s+[^\n]*\+", modes, re.MULTILINE), modes
            assert not re.search(r"^\s+5120x2160\s+[^\n]*\+", modes, re.MULTILINE), modes
            preferred_layout(machine)
            machine.wait_until_succeeds(user_command("i3-msg -t get_tree | grep Desktop-fixture"))
            machine.wait_until_succeeds(process("i3status-rs"), timeout=30)
            visible(machine, "Disk")
        else:
            user(machine, "systemctl --user is-active site-i3.target", True)
            user(machine, "systemctl --user is-active site-sway.target", True)
            im_pid = user(machine, "busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s org.fcitx.Fcitx5").strip().split()[1]
            im_parent = machine.succeed("ps -o ppid= -p " + im_pid).strip()
            assert im_parent in machine.succeed(process("kwin_wayland")).splitlines(), im_parent
            machine.succeed("tr '\\0' '\\n' < /proc/" + im_pid + "/environ | grep '^WAYLAND_SOCKET='")
            # Exercise the real Qt Wayland text-input path through KWin/Fcitx,
            # not a pre-rendered CJK string or a D-Bus name alone.
            user(machine, "systemd-run --user --collect --unit=ime-fixture sh -c 'QT_QPA_PLATFORM=wayland kdialog --title Native-input-check --inputbox \"Input method check\" > /run/user/1000/ime-result'")
            visible(machine, "Input method check")
            user(machine, "fcitx5-remote -s pinyin && fcitx5-remote -o")
            machine.send_chars("nihao ")
            machine.send_key("ret")
            machine.wait_until_succeeds(user_command("test -s /run/user/1000/ime-result"), timeout=30)
            entered = user(machine, "cat /run/user/1000/ime-result").strip()
            assert entered == "你好", entered
            controller = "busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 "
            user(machine, controller + "SetConfig sv fcitx://config/addon/pinyin 'a{sv}' 1 PageSize s 9")
            user(machine, controller + "Save")
            user(machine, "test ! -L ~/.config/fcitx5/profile; grep -Fx PageSize=9 ~/.config/fcitx5/conf/pinyin.conf; test -s ~/.local/share/fcitx5/pinyin/user.history")
            user(machine, "mkdir -p ~/.ssh/hosts.d; printf 'Host fixture\\n  HostName override.example\\n' > ~/.ssh/hosts.d/local.conf")
            assert "hostname override.example" in user(machine, "ssh -G fixture")
            identity_fixture(machine, "create")
            machine.succeed("systemctl restart site-identity.service")
            user(machine, "gpg --batch --import /run/site-identity/desktop/current/public.asc")
            keys = json.loads(user(machine, "cat ${identityDirectory}/metadata.json"))
            for purpose in ("github", "gitlab", "mainland", "vps", "ios"):
                user(machine, "gpg-connect-agent " + shlex.quote("KEYATTR " + keys[purpose]["keygrip"] + " Use-for-ssh: true") + " /bye")
            identity_ready(machine)
            assert user(machine, "ssh fixture-gitlab whoami").strip() == "desktop"
            user(machine, "git init ${identityDirectory}/repo && cd ${identityDirectory}/repo && git signing && git commit --allow-empty -m 'Declared GPG identity' && git verify-commit HEAD")
            identity_fixture(machine, "rotate")
            machine.succeed("systemctl restart site-identity.service")
            for purpose, enabled in (("github", "false"), ("gitlab", "false"), ("next", "true")):
                user(machine, "gpg-connect-agent " + shlex.quote("KEYATTR " + keys[purpose]["keygrip"] + " Use-for-ssh: " + enabled) + " /bye")
            identity_ready(machine)
            user(machine, "cd ${identityDirectory}/repo && git commit --allow-empty -m 'Updated SSH identity' && git verify-commit HEAD")
            machine.wait_until_succeeds(user_command("nmcli -g 802-11-wireless.ssid connection show synthetic-baseline | grep -Fx synthetic-baseline"), timeout=60)
            machine.wait_until_succeeds("nmcli -t -f DEVICE,TYPE device | grep '^wlan0:wifi$'", timeout=60)
            user(machine, "nmcli connection add type wifi con-name synthetic-saved ifname wlan0 ssid synthetic-saved wifi-sec.key-mgmt wpa-psk wifi-sec.psk synthetic-passphrase-2")
            machine.succeed("test $(stat -c %a /persist/etc/NetworkManager/system-connections/synthetic-saved.nmconnection) = 600")
            assert user(machine, "kreadconfig6 --file kdeglobals --group General --key font").startswith("Noto Sans,10,")
            assert user(machine, "kreadconfig6 --file kdeglobals --group General --key fixed").startswith("Sarasa Term SC,11,")
            user(machine, "kwriteconfig6 --file ~/.config/kdeglobals --group General --key font 'Noto Sans,12,-1,5,50,0,0,0,0,0'")
            for name in ("kdeglobals", "kwinrc", "plasmashellrc", "plasma-org.kde.plasma.desktop-appletsrc"):
                user(machine, f"test -w /persist/home/desktop/.config/{name} && test -L /home/desktop/.config/{name}")
            user(machine, "kwriteconfig6 --file /home/desktop/.config/kdeglobals --group VMTest --key State first-login; grep -Fx State=first-login /persist/home/desktop/.config/kdeglobals")
        # A process/window can exist before its first frame, and Plasma's
        # splash can still cover it. Capture the usable desktop, not startup.
        unlock(machine, session)
        visible(machine, "Native desktop", timeout=90)
        # Exercise the reminder's real GTK window and command interface in
        # the production service sandbox, then return to the active desktop.
        machine.wait_until_succeeds(user_command("systemctl --user is-active safeeyes.service"), timeout=60)
        machine.wait_until_succeeds(user_command("busctl --user status io.github.slgobinath.SafeEyes"), timeout=60)
        machine.wait_until_succeeds(user_command("timeout 10 safeeyes --status | grep 'Next break at'"), timeout=60)
        user(machine, "safeeyes --take-break")
        visible(machine, "Skip", timeout=30)
        user(machine, "safeeyes --disable")
        visible(machine, "Native desktop", timeout=30)
        if session in ("sway", "i3"):
            # The compositor owns clipboard helpers for the session. A short
            # transient service would terminate them when its main process exits.
            wm = "swaymsg" if session == "sway" else "i3-msg"
            user(machine, wm + " exec 'desktop-shot screen copy'")
            clipboard = "wl-paste --type image/png" if session == "sway" else "xclip -selection clipboard -t image/png -o"
            machine.wait_until_succeeds(user_command(clipboard + " > /run/user/1000/screenshot.png"), timeout=30)
            machine.succeed("test $(od -An -tx1 -N8 /run/user/1000/screenshot.png | tr -d ' \\n') = 89504e470d0a1a0a")
            user(machine, "desktop-shot screen save; test -s ~/Pictures/$(ls -t ~/Pictures | head -n1)")
        # Each session's one-minute timeout must invoke a working PAM lock.
        machine.send_key("ctrl")
        locker = {"sway": "swaylock", "i3": "i3lock", "KDE": "kscreenlocker_greet"}[session]
        machine.wait_until_succeeds(process(locker), timeout=85)
        unlock(machine, session)
        visible(machine, "Native desktop", timeout=30)
        if session in ("sway", "i3"):
            # The power menu and system suspend use the logind session path.
            user(machine, 'loginctl lock-session "$XDG_SESSION_ID"')
            machine.wait_until_succeeds(process(locker), timeout=30)
            unlock(machine, session)
            visible(machine, "Native desktop", timeout=30)
        # Exercise D-Bus activation after the WM's notifier has stopped, not
        # merely the explicit startup path. Plasma must own its native name.
        notifier = {"sway": "mako", "i3": "dunst", "KDE": "plasmashell"}[session]
        if session != "KDE":
            user(machine, "systemctl --user stop " + notifier + ".service")
            machine.wait_until_fails(process(notifier), timeout=30)
        # Software rendering and OCR can take longer than the normal 8-second
        # notification timeout. Keep this synthetic notification until teardown.
        user(machine, "notify-send --expire-time=0 --app-name=Desktop-check 'Desktop ready' '中文通知 · Session services ready'")
        owner = user(machine, "busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s org.freedesktop.Notifications").strip().split()[1]
        assert owner in machine.succeed(process(notifier)).splitlines(), (session, owner)
        for other in {"mako", "dunst"} - {notifier}:
            machine.fail(process(other))
        visible(machine, "Desktop ready", timeout=30)
        machine.screenshot("desktop-" + session.lower())
        if session == "sway":
            user(machine, "systemctl --user is-active kanshi.service")
            primary = json.loads(user(machine, "swaymsg -t get_outputs"))[0]["name"]
            def save_display_combination(expected):
                user(machine, "systemctl --user start wdisplays.service")
                visible(machine, r"(?i)Resolution|Scale", timeout=30)
                display_pid = user(machine, "systemctl --user show wdisplays.service --property=MainPID --value").strip()
                user(machine, "swaymsg '[pid=" + display_pid + "] focus'")
                # Alt+P focuses Position; Page Up moves it ten pixels right.
                # Ctrl+Enter activates the window's Apply button.
                for key in ("alt-p", "pgup", "tab"):
                    machine.send_key(key, delay=timedelta(milliseconds=150))
                visible(machine, r"Apply Changes", timeout=30)
                machine.send_key("ctrl-ret", delay=timedelta(milliseconds=150))
                machine.wait_until_succeeds(user_command("grep -F -- " + shlex.quote(expected) + " ~/.config/kanshi/config"), timeout=30)
                user(machine, "systemctl --user stop wdisplays.service")
            user(machine, "swaymsg output " + primary + " scale 1.25")
            save_display_combination("scale 1.25")
            user(machine, "swaymsg create_output")
            machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"HEADLESS-1\" and .active)'"))
            user(machine, "swaymsg output " + primary + " scale 1")
            width = next(o["rect"]["width"] for o in json.loads(user(machine, "swaymsg -t get_outputs")) if o["name"] == primary)
            # The gap accommodates the position edit in either display's tab.
            user(machine, "swaymsg output HEADLESS-1 scale 1.5 pos " + str(width + 32) + " 0")
            save_display_combination("scale 1.5")
            machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"HEADLESS-1\" and .scale == 1.5)'"))
            outputs = json.loads(user(machine, "swaymsg -t get_outputs"))
            active = sorted((o for o in outputs if o["active"]), key=lambda o: o["rect"]["x"])
            assert len(active) == 2 and active[1]["rect"]["x"] >= active[0]["rect"]["x"] + active[0]["rect"]["width"]
            user(machine, "swaymsg output HEADLESS-1 unplug")
            machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"" + primary + "\" and .scale == 1.25)'"))
        elif session == "i3":
            user(machine, "systemctl --user is-active autorandr.service")
            i3_output = user(machine, "xrandr --query | awk '/ connected/ {print $1; exit}'").strip()
            # Keep a profile for the monitor's boot-time EDID. Forcing a
            # virtio connector off removes its EDID until the next boot, so
            # the reconnect scenario below represents an EDID-less display.
            user(machine, "systemctl --user stop autorandr.service")
            user(machine, "xrandr --output " + shlex.quote(i3_output) + " --rotate left")
            user(machine, "autorandr --save vm-preference --force")
            user(machine, "systemctl --user start autorandr.service")
            # Reconnect the DRM output so the running session receives an
            # actual topology event and applies its display policy.
            user(machine, "xrandr --output " + shlex.quote(i3_output) + " --mode 5120x2160 --rotate normal")
            reconnect_i3_display(machine, i3_output)
            preferred_layout(machine)
            user(machine, "systemctl --user stop autorandr.service")
            user(machine, "xrandr --output " + shlex.quote(i3_output) + " --rotate left")
            user(machine, "autorandr --save vm-reconnected --force")
            user(machine, "systemctl --user start autorandr.service")
            user(machine, "xrandr --output " + shlex.quote(i3_output) + " --rotate normal")
            reconnect_i3_display(machine, i3_output)
            machine.wait_until_succeeds(user_command("autorandr --current | grep -Fx vm-reconnected"), timeout=30)
        # Stopping the display manager tears down the real user session.
        stop_session(machine, compositor)
        if session in ("sway", "i3"):
            machine.reboot()
            login_session(machine, session, compositor)
            assert user(machine, "timeout 15 secret-tool lookup purpose desktop-test").strip() == "wallet-fixture"
            if session == "sway":
                machine.wait_until_succeeds(user_command("systemctl --user is-active kanshi.service"))
                machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"" + primary + "\" and .scale == 1.25)'"))
                user(machine, "swaymsg create_output")
                machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"HEADLESS-1\" and .scale == 1.5)'"))
            else:
                try:
                    machine.wait_until_succeeds(user_command("autorandr --current | grep vm-preference"), timeout=60)
                except Exception:
                    print(user(machine, "autorandr --debug --detected; autorandr --fingerprint; cat ~/.config/autorandr/vm-preference/setup ~/.config/autorandr/vm-preference/config"))
                    print(user(machine, "journalctl --user -u autorandr.service --no-pager"))
                    print(user(machine, "xrandr --query"))
                    raise
                outputs = user(machine, "xrandr --query")
                assert re.search(r"^" + re.escape(i3_output) + r" connected[^\n]* left ", outputs, re.MULTILINE), outputs
            stop_session(machine, compositor)
        if session == "KDE":
            learned = machine.succeed("sha256sum /persist/home/desktop/.local/share/fcitx5/pinyin/user.dict /persist/home/desktop/.local/share/fcitx5/pinyin/user.history")
            # Recreate the home link as an ephemeral root would, while keeping
            # its existing persistent data. Atomic writes must survive reboot.
            machine.succeed("test -L /home/desktop/.config/kdeglobals && rm /home/desktop/.config/kdeglobals")
            machine.reboot()
            login_session(machine, session, compositor)
            assert user(machine, "timeout 15 secret-tool lookup purpose desktop-test").strip() == "wallet-fixture"
            user(machine, "test -L /home/desktop/.config/kdeglobals && grep -Fx State=first-login /persist/home/desktop/.config/kdeglobals")
            assert user(machine, "kreadconfig6 --file kdeglobals --group General --key font").startswith("Noto Sans,12,")
            machine.wait_until_succeeds(user_command("kreadconfig6 --file gtk-3.0/settings.ini --group Settings --key gtk-font-name | grep -E '^Noto Sans,? +12$'"), timeout=30)
            user(machine, "kwriteconfig6 --file /home/desktop/.config/kdeglobals --group VMTest --key State after-reboot; grep -Fx State=after-reboot /persist/home/desktop/.config/kdeglobals")
            machine.wait_until_succeeds(user_command("busctl --user status org.fcitx.Fcitx5"))
            assert '"PageSize" s "9"' in user(machine, controller + "GetConfig s fcitx://config/addon/pinyin")
            assert learned == machine.succeed("sha256sum /persist/home/desktop/.local/share/fcitx5/pinyin/user.dict /persist/home/desktop/.local/share/fcitx5/pinyin/user.history")
            assert "hostname override.example" in user(machine, "ssh -G fixture")
            identity_ready(machine)
            user(machine, "cd ${identityDirectory}/repo && git verify-commit HEAD && git commit --allow-empty -m 'Identity after reboot' && git verify-commit HEAD")
            machine.wait_until_succeeds(user_command("nmcli -g 802-11-wireless.ssid connection show synthetic-baseline | grep -Fx synthetic-baseline"), timeout=60)
            assert user(machine, "nmcli -g 802-11-wireless.ssid connection show synthetic-saved").strip() == "synthetic-saved"
            assert machine.succeed("nmcli -s -g 802-11-wireless-security.psk connection show synthetic-saved").strip() == "synthetic-passphrase-2"
            user(machine, "test -s /persist/home/desktop/.config/kwinoutputconfig.json")
            stop_session(machine, compositor)

    # Sessions use separate guests. Report each one's lifecycle result even
    # when another session fails, and fail the complete test on any error.
    failures = []
    for machine, session, compositor in ((plasma, "KDE", "plasmashell"), (sway, "sway", "sway"), (i3, "i3", "i3")):
        try:
            with subtest(session):
                machine.start(allow_reboot=True)
                exercise_session(machine, session, compositor)
        except Exception as error:
            traceback.print_exc()
            failures.append((session, str(error)))
            # The remote executor retains this log even if Nix discards the
            # failed output. Capture the synthetic screen for any UI failure.
            try:
                with tempfile.TemporaryDirectory() as directory:
                    frame = Path(directory) / "failure.png"
                    machine.screenshot(str(frame))
                    print("DESKTOP_FRAME_" + session + "_PNG=" + base64.b64encode(frame.read_bytes()).decode())
                print(machine.execute("journalctl _UID=1000 -n 60 --no-pager")[1])
                if session == "KDE":
                    print(machine.execute("journalctl -u site-identity.service -u sshd.service -n 80 --no-pager")[1])
                    print(machine.execute("systemctl status site-identity.service; journalctl -u site-identity.service -n 80 --no-pager")[1])
                print(machine.execute("tail -n 80 /run/user/1000/safeeyes/safeeyes.log")[1])
                print(machine.execute(user_command("systemctl --user show-environment | grep -E '^(DISPLAY|WAYLAND_DISPLAY|SWAYSOCK|I3SOCK|XDG_SESSION_ID|XDG_SESSION_TYPE)='"))[1])
                if session == "i3":
                    print(machine.execute("pid=$(pgrep -u 1000 -x xss-lock); tr '\\0' '\\n' < /proc/$pid/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_SESSION_ID|XDG_SESSION_TYPE)='")[1])
            except Exception as diagnostic_error:
                print("Could not collect desktop diagnostics:", diagnostic_error)
        finally:
            machine.shutdown()
    assert not failures, failures
  '';
}
