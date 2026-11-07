{ inputs }:
{ pkgs, lib, ... }:
let
  identityDirectory = "/home/desktop/.local/state/identity-fixture";
  identitySource = "/persist/home/desktop/.local/state/identity-fixture/identity.yaml";
  identityFixture = "${
    pkgs.python3.withPackages (ps: [ ps.pyyaml ])
  }/bin/python3 ${../fixtures/gpg_identity.py}";
  wallpaper = import ../../nix/wallpaper.nix { inherit pkgs; };
  certificates = import (pkgs.path + /nixos/tests/nginx/proxyprotocol/snakeoil-certs.nix);
  wallpaperImages =
    pkgs.runCommand "wallpaper-fixture"
      {
        nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pillow ])) ];
      }
      ''
        mkdir -p "$out"
        python3 - "$out" <<'PY'
        import json, sys
        from pathlib import Path
        from PIL import Image
        root = Path(sys.argv[1])
        images = []
        for date, color in (("202601010000", (180, 40, 70)), ("202601020000", (40, 70, 180))):
            Image.new("RGB", (64, 64), color).save(root / (date + ".jpg"))
            images.append({"fullstartdate": date, "url": "/" + date + ".jpg"})
        Image.new("RGB", (64, 64), (40, 160, 70)).save(root / "personal.png")
        (root / "feed.json").write_text(json.dumps({"images": images}))
        PY
      '';

in
{
  name = "native-desktop-sessions";
  enableOCR = true;
  globalTimeout = 1800;
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
    time.timeZone = "America/New_York";
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
    site.connections.enable = true;
    networking.extraHosts = "127.0.0.1 wallpaper.test.nix";
    security.pki.certificateFiles = [ certificates.ca.cert ];
    services.nginx = {
      enable = true;
      virtualHosts."wallpaper.test.nix" = {
        onlySSL = true;
        listen = [
          {
            addr = "127.0.0.1";
            port = 8449;
            ssl = true;
          }
        ];
        sslCertificate = certificates."*.test.nix".cert;
        sslCertificateKey = certificates."*.test.nix".key;
        root = wallpaperImages;
        locations."= /feed.json".proxyPass = "http://127.0.0.1:8450";
      };
    };
    systemd.services.wallpaper-feed = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "wallpaper-feed.py" ''
        import time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from pathlib import Path

        class Feed(BaseHTTPRequestHandler):
            def do_GET(self):
                with Path('/run/wallpaper-requests').open('a') as requests:
                    requests.write('feed\n')
                deadline = time.monotonic() + 30
                while Path('/run/wallpaper-hold').exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                body = Path('${wallpaperImages}/feed.json').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        ThreadingHTTPServer(('127.0.0.1', 8450), Feed).serve_forever()
      ''}";
    };
    systemd.user.services.site-wallpaper-fetch.serviceConfig.ExecStart =
      lib.mkForce "${wallpaper}/bin/site-wallpaper fetch --feed-url https://wallpaper.test.nix:8449/feed.json";
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
      imports = [ ../../profiles/laptop/boot.nix ];
      virtualisation = {
        emptyDiskImages = lib.mkForce [
          512
          1024
        ];
        useBootLoader = true;
        mountHostNixStore = true;
        useEFIBoot = true;
      };
      boot.loader.systemd-boot.enable = true;
      # Keep the test driver's serial logs while displaying the graphical
      # passphrase prompt on the VM's framebuffer.
      boot.kernelParams = [ "plymouth.ignore-serial-consoles" ];
      boot.initrd.kernelModules = [ "virtio_gpu" ];
      environment.systemPackages = [ pkgs.cryptsetup ];
      specialisation.boot-luks.configuration = {
        boot.initrd.luks.devices = lib.mkVMOverride {
          cryptroot.device = "/dev/vdc";
        };
        virtualisation.rootDevice = "/dev/mapper/cryptroot";
      };
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
    import struct
    import subprocess
    import time
    from datetime import datetime, timedelta, timezone
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
    power_menu = runpy.run_path("${./power_menu.py}")

    def power_visible(machine, pattern, **kwargs):
        # The i3 power actions follow the saved left-rotation profile. QEMU
        # captures the physical framebuffer; turn it upright for OCR while
        # keeping the guest's real rotated layout and original screenshots.
        return visible(machine, pattern, rotation=90 if machine.name == "i3" else 0, **kwargs)

    def unlock(machine, session, screenshot=None):
        locker = {"sway": "swaylock", "i3": "i3lock", "KDE": "kscreenlocker_greet"}[session]
        if machine.execute(process(locker))[0] == 0:
            if session == "KDE":
                machine.send_key("ctrl")
                visible(machine, "Switch User")
                # Breeze hides the password controls after ten idle seconds.
                # OCR can outlast that interval; wake them again and let the
                # authentication prompt regain focus before typing.
                machine.send_key("ctrl", delay=timedelta(milliseconds=150))
                machine.sleep(1)
            else:
                machine.sleep(1)
            # Capture after the native lock surface has had time to paint,
            # immediately before entering the password, not on process spawn.
            if screenshot:
                machine.screenshot(screenshot)
            # QEMU holds each key for 100 ms. Let the clear chord release
            # before entering the password through the greeter's keyboard.
            machine.send_key("ctrl-u", delay=timedelta(milliseconds=150))
            machine.send_chars("synthetic-fixture-only", delay=timedelta(milliseconds=150))
            machine.send_key("ret")
            machine.wait_until_fails(process(locker), timeout=30)

    def stop_session(machine, compositor, menu=False):
        # Finish the synthetic terminal workload before asking the desktop to
        # log out, so Kitty's running-command confirmation needs no response.
        machine.execute(user_command("systemctl --user stop desktop-fixture.service"), timeout=30)
        if compositor == "plasmashell":
            # Session autostarts include services outside the plasma-* names.
            # Finish their startup transaction before requesting its shutdown.
            machine.wait_until_succeeds(user_command(
                "test -z \"$(systemctl --user list-jobs --no-legend --plain)\""
            ), timeout=90)
        command = {"sway": "swaymsg exit", "i3": "i3-msg exit",
                   "plasmashell": "busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logout"}[compositor]
        # Return to the greeter through the session's own logout entrypoint.
        # Its transient command can be terminated with the graphical session.
        if menu:
            power_menu["confirm"](machine, user, power_visible, "Log out", shortcut=compositor != "plasmashell")
        else:
            status, output = machine.execute(user_command(command), timeout=30)
            if status:
                print("Session logout command:", status, output)
        try:
            for unit in ("graphical-session.target", "desktop-health.timer", "site-sway.target", "site-i3.target", "site-wallpaper.timer", "site-wallpaper-fetch@*.timer"):
                machine.wait_until_fails(user_command("systemctl --user is-active " + shlex.quote(unit)), timeout=60)
            # A late notification must not restart a notifier after logout.
            user(machine, "notify-send 'Session has ended'", True)
            for name in (compositor, "waybar", "mako", "dunst", "fcitx5"):
                machine.wait_until_fails(process(name), timeout=60)
            machine.wait_for_unit("display-manager.service")
            visible(machine, r"(?i)\bdesktop\b", timeout=60)
            # Cover the logout interval even when the next login creates a
            # new user manager and resets its service restart counters.
            crashes = machine.succeed("journalctl -b COREDUMP_COMM=pipewire --no-pager -q -o cat")
            assert not crashes.strip(), crashes
        except Exception:
            for command in ("loginctl list-sessions", "ps -u 1000 -o pid,ppid,comm",
                            user_command("systemctl --user status 'site-session-watch@*.service' graphical-session.target"),
                            "journalctl _UID=1000 -n 80 --no-pager"):
                print(command, machine.execute(command)[1])
            raise

    def power_workloads(machine):
        # A real paused VM process belongs to another user. System power actions
        # must protect it as well as the current user's GUI applications.
        machine.succeed("systemd-run --unit=vm-workload --property=User=nobody ${pkgs.qemu}/bin/qemu-system-x86_64 -machine none -display none -nodefaults -S")
        machine.wait_for_unit("vm-workload.service")
        power_menu["blocked"](machine, user, visible, "Reboot", "QEMU", shortcut=True)
        machine.succeed("systemctl stop vm-workload.service")
        # Queue a backup behind an activating prerequisite; no real data or
        # repository credentials are involved in this systemd workload.
        machine.succeed("systemd-run --unit=backup-prerequisite --no-block --property=Type=oneshot sleep 600")
        machine.succeed("systemd-run --unit=site-backup-fixture-backup --no-block --property=After=backup-prerequisite.service --property=Type=oneshot sleep 600")
        power_menu["blocked"](machine, user, visible, "Power off", "site-backup-fixture-backup", shortcut=True)
        machine.succeed("systemctl stop backup-prerequisite.service")
        machine.wait_until_succeeds("systemctl show site-backup-fixture-backup.service -p MainPID --value | grep -v '^0$'", timeout=30)
        power_menu["blocked"](machine, user, visible, "Reboot", "site-backup-fixture-backup", shortcut=True)
        machine.succeed("systemctl stop site-backup-fixture-backup.service")

    def encrypted_boot(machine):
        # This disk is created by the VM test and contains only synthetic state.
        machine.succeed("printf synthetic-disk-passphrase | cryptsetup luksFormat -q --iter-time=1 /dev/vdc -")
        machine.succeed("printf synthetic-disk-passphrase | cryptsetup luksOpen --key-file - /dev/vdc cryptroot")
        machine.succeed("mkfs.ext4 /dev/mapper/cryptroot")
        # A bootloader VM seeds its Nix database in the original root image;
        # unlike direct boot, its command line has no regInfo to recreate it.
        # Migrate the initialized synthetic root with its database and profile
        # state, keeping separate mounts (persist/store/boot) in place.
        machine.succeed("mkdir -p /mnt/encrypted-root && mount /dev/mapper/cryptroot /mnt/encrypted-root")
        machine.succeed("systemctl stop nix-daemon.socket nix-daemon.service")
        machine.succeed("${pkgs.rsync}/bin/rsync -aHAXx --exclude=/mnt --exclude=/tmp / /mnt/encrypted-root/")
        machine.succeed("umount /mnt/encrypted-root")
        machine.succeed("/run/current-system/specialisation/boot-luks/bin/switch-to-configuration boot")
        machine.succeed("sync")
        machine.crash()
        machine.start()
        # Enter the passphrase through the graphical console's keyboard.
        visible(machine, r"(?i)passphrase|password|unlock", timeout=180, keep_active=False)
        machine.screenshot("boot-plymouth-breeze-unlock")
        machine.send_chars("synthetic-disk-passphrase", delay=timedelta(milliseconds=150))
        machine.send_key("ret")
        machine.wait_for_unit("display-manager.service", timeout=180)
        machine.succeed("findmnt -n -o SOURCE / | grep -Fx /dev/mapper/cryptroot")
        login_session(machine, "sway", "sway")
        machine.screenshot("boot-unlocked-sway")
        stop_session(machine, "sway", menu=True)

    def login_session(machine, session, compositor):
        login(machine)
        machine.wait_until_succeeds(process(compositor), timeout=180)
        machine.wait_until_succeeds(user_command("systemctl --user is-active graphical-session.target desktop-health.timer"), timeout=60)
        # A compositor process exists before its config imports the session
        # environment. Wait for that explicit readiness boundary.
        machine.wait_until_succeeds(user_command("systemctl --user show-environment | grep '^XDG_CURRENT_DESKTOP=.*" + session + "'"), timeout=60)
        machine.wait_until_succeeds(user_command("busctl --user status org.fcitx.Fcitx5"), timeout=60)
        if session == "KDE":
            # Plasma's calendar starts Akonadi after the initial startup jobs
            # finish. Exercise logout from the ready desktop: KDE's native
            # StopUnit(..., "fail") otherwise conflicts with that late start.
            machine.wait_until_succeeds(user_command("systemctl --user is-active akonadi_control.service"), timeout=60)
    layout_query = '[.[] | select(.active) | {key: .name, value: {active, scale, rect, current_mode, transform}}] | from_entries'

    def display_layout(machine):
        return json.loads(user(machine, "swaymsg -t get_outputs | jq " + shlex.quote(layout_query)))

    def assert_display_layout(machine, expected):
        query = '(' + layout_query + ') == ' + json.dumps(expected)
        machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e " + shlex.quote(query)), timeout=30)

    def bar_pixels(machine, frame, raw):
        machine.screenshot(str(frame))
        width, height = struct.unpack(">II", frame.read_bytes()[16:24])
        with raw.open("wb") as stream:
            subprocess.run(["pngtopnm", str(frame)], stdout=stream, check=True, timeout=10)
        pixels = subprocess.check_output(["magick", str(raw), "-crop", f"{width}x1+0+2", "-depth", "8", "RGB:-"], timeout=10)
        return width, height, pixels

    def wallpaper_visible(machine, session):
        selected = Path(user(machine, "cat ~/.local/state/site-wallpaper/current").strip()).name
        expected = {"202601010000.jpg": (180, 40, 70), "202601020000.jpg": (40, 70, 180),
                    "personal.png": (40, 160, 70)}[selected]
        user(machine, ("swaymsg" if session == "sway" else "i3-msg") + " workspace 9")
        with tempfile.TemporaryDirectory() as temporary:
            frame = Path(temporary) / "background.png"
            raw = Path(temporary) / "background.ppm"
            deadline = time.monotonic() + 20
            while True:
                machine.screenshot(str(frame), timeout=gui["remaining"](deadline))
                width, height = struct.unpack(">II", frame.read_bytes()[16:24])
                with raw.open("wb") as stream:
                    subprocess.run(["pngtopnm", str(frame)], stdout=stream, check=True, timeout=gui["remaining"](deadline))
                pixel = subprocess.check_output(["magick", str(raw), "-crop", f"1x1+{width//3}+{height//2}", "-depth", "8", "RGB:-"], timeout=gui["remaining"](deadline))
                if len(pixel) == 3 and all(abs(a-b) < 5 for a, b in zip(pixel, expected)):
                    break
                assert time.monotonic() < deadline, (selected, list(pixel))
                time.sleep(0.2)
        user(machine, ("swaymsg" if session == "sway" else "i3-msg") + " workspace 1")
        return selected

    def wallpaper_fetch_state(machine):
        return json.loads(user(machine, "cat ~/.local/state/site-wallpaper/fetch.json"))

    def wallpaper_due(machine):
        # Move only the synthetic persisted deadline; the production timer,
        # service, HTTPS collection and display path execute unchanged.
        state = wallpaper_fetch_state(machine)
        now = int(machine.succeed("date +%s"))
        state["lastAttempt"] = datetime.fromtimestamp(now - 3601, timezone.utc).isoformat()
        user(machine, "printf '%s' " + shlex.quote(json.dumps(state)) + " > ~/.local/state/site-wallpaper/fetch.json")
        user(machine, "systemctl --user start site-wallpaper-schedule.service")
        return state["lastAttempt"]

    def wallpaper_attempt_finished(machine, previous, result):
        condition = 'select(.lastAttempt != $previous and .result == $result)'
        machine.wait_until_succeeds(user_command(
            "jq -e --arg previous " + shlex.quote(previous) + " --arg result " + shlex.quote(result)
            + " " + shlex.quote(condition) + " ~/.local/state/site-wallpaper/fetch.json"
        ), timeout=45)
        machine.wait_until_succeeds(user_command(
            "systemctl --user list-units --all --output=json 'site-wallpaper-fetch@*.timer'"
            " | jq -e '[.[] | select(.sub == \"waiting\")] | length == 1'"
        ), timeout=30)

    def click_eye(machine, color, expected):
        # Locate the visible button's background and click through the VM tablet.
        with tempfile.TemporaryDirectory() as temporary:
            frame, raw = Path(temporary) / "eye.png", Path(temporary) / "eye.ppm"
            width, height, pixels = bar_pixels(machine, frame, raw)
            positions = [x for x in range(width) if pixels[3*x:3*x+3] == bytes.fromhex(color)]
            assert positions, "Idle inhibitor button is not visible"
            x = positions[len(positions)//2]
            machine.click(x, 12, width, height)
            deadline = time.monotonic() + 10
            while True:
                machine.screenshot(str(frame), timeout=gui["remaining"](deadline))
                with raw.open("wb") as stream:
                    subprocess.run(["pngtopnm", str(frame)], stdout=stream, check=True, timeout=gui["remaining"](deadline))
                pixel = subprocess.check_output(["magick", str(raw), "-crop", f"1x1+{x}+2", "-depth", "8", "RGB:-"], timeout=gui["remaining"](deadline))
                if pixel == bytes.fromhex(expected):
                    break
                assert time.monotonic() < deadline, "Idle inhibitor button did not change state"
                time.sleep(0.1)

    def hover_status(machine):
        output = json.loads(user(machine, "swaymsg -t get_outputs"))[0]
        original = output["current_mode"]
        user(machine, "swaymsg output " + output["name"] + " mode 1920x1080")
        visible(machine, "Native desktop", timeout=30)
        with tempfile.TemporaryDirectory() as temporary:
            frame, raw = Path(temporary) / "bar.png", Path(temporary) / "bar.ppm"
            width, height, pixels = bar_pixels(machine, frame, raw)
            assert (width, height) == (1920, 1080), (width, height)
            networks = [x for x in range(width) if pixels[3*x:3*x+3] == bytes.fromhex("21618c")]
            clocks = [x for x in range(width) if pixels[3*x:3*x+3] == bytes.fromhex("45525e")]
            assert networks and clocks, "Network and clock modules must be visible"
            for name, x, text in (("network", networks[0] + 10, r"(?i)Interface.*eth"),
                                  ("calendar", clocks[0] + 20, r"(?i)Mo.*Tu.*We"),
                                  ("shanghai", clocks[-1] - 20, r"Asia/Shanghai")):
                machine.move_pointer(x, 12, width, height)
                visible(machine, text, timeout=20, keep_active=False)
                machine.screenshot("desktop-tooltip-" + name)
            machine.move_pointer(width // 2, height // 2, width, height)
        user(machine, "swaymsg output " + output["name"] + " mode " + str(original["width"]) + "x" + str(original["height"]))

    def exercise_session(machine, session, compositor):
        machine.wait_for_unit("persist.mount")
        machine.wait_for_unit("home-manager-desktop.service")
        if session in ("sway", "i3"):
            now = int(machine.succeed("date +%s"))
            saved_fetch = {"lastAttempt": datetime.fromtimestamp(now, timezone.utc).isoformat(), "result": "unchanged"}
            machine.succeed("install -d -o desktop -g users /home/desktop/Pictures/wallpaper /home/desktop/.local/state/site-wallpaper")
            machine.succeed("install -o desktop -g users ${wallpaperImages}/personal.png /home/desktop/Pictures/wallpaper/personal.png")
            machine.succeed("runuser -u desktop -- sh -c " + shlex.quote(
                "printf '%s' /home/desktop/Pictures/wallpaper/personal.png > ~/.local/state/site-wallpaper/current; "
                "printf '%s' " + shlex.quote(json.dumps(saved_fetch)) + " > ~/.local/state/site-wallpaper/fetch.json"
            ))
        visible(machine, r"(?i)\bdesktop\b", timeout=90)
        machine.screenshot("sddm-" + machine.name)
        login_session(machine, session, compositor)
        unlock(machine, session)
        if session in ("sway", "i3"):
            machine.wait_for_unit("nginx.service")
            assert wallpaper_visible(machine, session) == "personal.png"
            assert wallpaper_fetch_state(machine) == saved_fetch
            machine.succeed("test ! -e /run/wallpaper-requests")
            # Hold the HTTPS response while observing the restored local background.
            machine.succeed("touch /run/wallpaper-hold")
            previous_attempt = wallpaper_due(machine)
            machine.wait_until_succeeds("test -s /run/wallpaper-requests", timeout=20)
            assert wallpaper_visible(machine, session) == "personal.png"
            machine.succeed("rm /run/wallpaper-hold")
            wallpaper_attempt_finished(machine, previous_attempt, "new")
            machine.wait_until_succeeds(user_command("grep -F 202601020000.jpg ~/.local/state/site-wallpaper/current"), timeout=30)
            assert wallpaper_visible(machine, session) == "202601020000.jpg"
            initial_files = user(machine, "stat -c '%n %i %Y' ~/Pictures/wallpaper/*")
            assert len(initial_files.splitlines()) == 3, initial_files
            previous_attempt = wallpaper_due(machine)
            wallpaper_attempt_finished(machine, previous_attempt, "unchanged")
            assert user(machine, "stat -c '%n %i %Y' ~/Pictures/wallpaper/*") == initial_files
            previous = wallpaper_visible(machine, session)
            machine.succeed("systemctl stop nginx")
            previous_attempt = wallpaper_due(machine)
            wallpaper_attempt_finished(machine, previous_attempt, "failed")
            assert wallpaper_visible(machine, session) == previous
            user(machine, "systemctl --user start site-wallpaper.service")
            assert wallpaper_visible(machine, session) != previous
            user(machine, ("swaymsg" if session == "sway" else "i3-msg") + " reload")
            wallpaper_visible(machine, session)
            machine.succeed("systemctl start nginx")
        else:
            user(machine, "systemctl --user is-active site-wallpaper.timer", True)
        machine.wait_until_succeeds(user_command("printf 'wallet-fixture' | timeout 20 secret-tool store --label=Desktop-test purpose desktop-test"), timeout=60)
        assert user(machine, "timeout 15 secret-tool lookup purpose desktop-test").strip() == "wallet-fixture"
        user(machine, "gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Properties.Get org.freedesktop.portal.Settings version")
        assert user(machine, "xdg-mime query default inode/directory").strip() == "org.kde.dolphin.desktop"
        # PipeWire may be socket activated on a VM with no sound hardware.
        user(machine, "timeout 20 pw-cli info 0")
        machine.wait_until_succeeds(user_command("systemctl --user is-active pipewire.service wireplumber.service"), timeout=60)
        # Launch through the actual imported systemd user environment.
        font_sample = "Native desktop / 原生桌面\nABCD|ABCD|\n中文|中文|\n0O 1lI == === != => <= <=> ->\n☺ ☺️ ❤ ❤️ ✈ ✈️\n😀 🚀 🧪 👩🏽‍💻 🇨🇳 1️⃣\n"
        terminal = "printf '%s' " + shlex.quote(font_sample) + "; sleep 600"
        user(machine, "systemd-run --user --collect --unit=desktop-fixture kitty --debug-font-fallback --title Desktop-fixture sh -c " + shlex.quote(terminal))
        machine.wait_until_succeeds(user_command("systemctl --user is-active desktop-fixture.service"))
        machine.wait_until_succeeds(process("kitty"))
        # Wait for the actual window, including Plasma's software-rendered splash.
        visible(machine, "Native desktop", timeout=180)
        machine.screenshot("kitty-fonts-" + machine.name)
        if session == "sway":
            user(machine, "systemctl --user is-active site-sway.target waybar.service mako.service nm-applet.service")
            user(machine, "systemctl --user is-active site-i3.target", True)
            machine.wait_until_succeeds(user_command("swaymsg -t get_tree | grep Desktop-fixture"))
        elif session == "i3":
            user(machine, "systemctl --user is-active site-i3.target dunst.service autorandr.service nm-applet.service")
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
        if session in ("sway", "i3"):
            wm = "swaymsg" if session == "sway" else "i3-msg"
            user(machine, "systemd-run --user --collect --unit=tabbed-fixture kitty --title Tabbed-fixture sleep 120")
            query = '[.. | objects | select(.layout? == "tabbed") | [.. | objects | select(.name? == "Desktop-fixture" or .name? == "Tabbed-fixture")] | length] | any(. >= 2)'
            machine.wait_until_succeeds(user_command(wm + " -t get_tree | jq -e " + shlex.quote(query)), timeout=30)
            user(machine, "systemctl --user stop tabbed-fixture.service")
            visible(machine, "Native desktop", timeout=30)
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
        if session == "sway":
            hover_status(machine)
            click_eye(machine, "2d3436", "ecf0f1")
            machine.sleep(65)
            machine.fail(process("swaylock"))
            machine.screenshot("desktop-sway-keep-active")
            machine.send_key("meta_l-semicolon", delay=timedelta(milliseconds=150))
            machine.wait_until_succeeds(process("swaylock"), timeout=30)
            unlock(machine, session)
            click_eye(machine, "ecf0f1", "2d3436")
        machine.send_key("ctrl")
        locker = {"sway": "swaylock", "i3": "i3lock", "KDE": "kscreenlocker_greet"}[session]
        machine.wait_until_succeeds(process(locker), timeout=85)
        unlock(machine, session, screenshot="desktop-" + session.lower() + "-idle-lock")
        visible(machine, "Native desktop", timeout=30)
        if session in ("sway", "i3"):
            machine.send_key("meta_l-semicolon", delay=timedelta(milliseconds=150))
            machine.wait_until_succeeds(process(locker), timeout=30)
            unlock(machine, session, screenshot="desktop-" + session + "-manual-lock")
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
                return display_layout(machine)
            user(machine, "swaymsg output " + primary + " scale 1.25")
            saved_single = save_display_combination("scale 1.25")
            user(machine, "swaymsg create_output")
            machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"HEADLESS-1\" and .active)'"))
            user(machine, "swaymsg output " + primary + " scale 1")
            width = next(o["rect"]["width"] for o in json.loads(user(machine, "swaymsg -t get_outputs")) if o["name"] == primary)
            # The gap accommodates the position edit in either display's tab.
            user(machine, "swaymsg output HEADLESS-1 scale 1.5 pos " + str(width + 32) + " 0")
            saved_dual = save_display_combination("scale 1.5")
            machine.wait_until_succeeds(user_command("swaymsg -t get_outputs | jq -e '.[] | select(.name == \"HEADLESS-1\" and .scale == 1.5)'"))
            outputs = json.loads(user(machine, "swaymsg -t get_outputs"))
            active = sorted((o for o in outputs if o["active"]), key=lambda o: o["rect"]["x"])
            assert len(active) == 2 and active[1]["rect"]["x"] >= active[0]["rect"]["x"] + active[0]["rect"]["width"]
            user(machine, "swaymsg output HEADLESS-1 unplug")
            assert_display_layout(machine, saved_single)
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
        if session in ("sway", "i3"):
            wallpaper_visible(machine, session)
        if session == "sway":
            power_workloads(machine)
        if session in ("sway", "i3"):
            saved_wallpaper = wallpaper_visible(machine, session)
            saved_fetch = wallpaper_fetch_state(machine)
            requests = machine.succeed("cat /run/wallpaper-requests")
        stop_session(machine, compositor, menu=True)
        login_session(machine, session, compositor)
        if session == "sway":
            assert_display_layout(machine, saved_single)
        elif session == "i3":
            machine.wait_until_succeeds(user_command("autorandr --current | grep vm-reconnected"), timeout=60)
        if session in ("sway", "i3"):
            assert wallpaper_visible(machine, session) == saved_wallpaper
            assert wallpaper_fetch_state(machine) == saved_fetch
            assert machine.succeed("cat /run/wallpaper-requests") == requests
        if session in ("sway", "i3"):
            boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
            power_menu["confirm"](machine, user, power_visible, "Reboot", shortcut=True)
            machine.machine.connected = False
            machine.wait_for_unit("display-manager.service", timeout=180)
            assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
            login_session(machine, session, compositor)
            assert user(machine, "timeout 15 secret-tool lookup purpose desktop-test").strip() == "wallet-fixture"
            assert wallpaper_visible(machine, session) == saved_wallpaper
            assert wallpaper_fetch_state(machine) == saved_fetch
            machine.succeed("test ! -e /run/wallpaper-requests")
            if session == "sway":
                machine.wait_until_succeeds(user_command("systemctl --user is-active kanshi.service"))
                assert_display_layout(machine, saved_single)
                user(machine, "swaymsg create_output")
                assert_display_layout(machine, saved_dual)
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
            # Use the same native lock after restoring a multi-output or
            # rotated layout, then authenticate through its actual PAM UI.
            machine.send_key("meta_l-semicolon", delay=timedelta(milliseconds=150))
            machine.wait_until_succeeds(process(locker), timeout=30)
            unlock(machine, session, screenshot="desktop-" + session + "-layout-lock")
            stop_session(machine, compositor)
        if session == "KDE":
            stop_session(machine, compositor)
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
        machine = gui["Desktop"](machine)
        try:
            with subtest(session):
                machine.start(allow_reboot=True)
                exercise_session(machine, session, compositor)
                if session == "sway":
                    encrypted_boot(machine)
                elif session == "i3":
                    login_session(machine, session, compositor)
                    power_menu["confirm"](machine, user, power_visible, "Power off", shortcut=True)
                    machine.wait_for_shutdown(timeout=timedelta(seconds=120))
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
                print(machine.execute("journalctl -b -u home-manager-desktop.service -n 80 --no-pager")[1])
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
            try:
                machine.shutdown()
            except Exception as error:
                failures.append((session, "shutdown: " + str(error)))
    assert not failures, failures
  '';
}
