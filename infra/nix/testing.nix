# Reusable NixOS QEMU VM test constructors, container host fixture, and offline Sway + VS Code fixture.
let
  vscodeOverlay = import ./vscode.nix;
  testingDir = ../testing;
  runtimePy = ../testing/runtime.py;
  guiPy = ../testing/gui.py;
  vscodeCdpPy = ../testing/vscode_cdp.py;

  mkTest =
    pkgs: testModule:
    pkgs.testers.runNixOSTest {
      imports = [ testModule ];
      qemu.forceAccel = pkgs.lib.mkDefault true;
    };

  mkContainerHostModule =
    {
      user ? "desktop",
      uid ? 1000,
      gid ? 1000,
    }:
    { pkgs, lib, ... }:
    {
      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          live-restore = true;
          log-driver = "local";
          runtimes.runsc = {
            path = "${pkgs.gvisor}/bin/runsc";
            runtimeArgs = [ "--platform=systrap" ];
          };
        };
      };

      users.groups.${user} = lib.mkIf (user != "users") {
        inherit gid;
      };

      users.users.${user} = {
        isNormalUser = true;
        inherit uid;
        group = lib.mkDefault (if user != "users" then user else "users");
        extraGroups = [
          "docker"
          "wheel"
        ];
        subUidRanges = [
          {
            startUid = 100000;
            count = 65536;
          }
        ];
        subGidRanges = [
          {
            startGid = 100000;
            count = 65536;
          }
        ];
      };

      environment.systemPackages = with pkgs; [
        skopeo
        jq
        docker-compose
        git
        curl
      ];
    };

  mkSwayEditorModule =
    {
      user ? "desktop",
      uid ? 1000,
      gid ? 1000,
    }:
    { pkgs, lib, ... }:
    let
      homeDir = "/home/${user}";
      serverDownloadFolder = "${homeDir}/.cache/vscode-server-downloads";
      vscodeCommit = pkgs.vscode.rev;

      vscodeServerArchive =
        pkgs.runCommand "vscode-server-${vscodeCommit}-offline.tar.gz"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.gnutar
              pkgs.gzip
              pkgs.findutils
            ];
          }
          ''
            expected_commit="$(jq -r .commit ${pkgs.vscode}/lib/vscode/resources/app/product.json)"
            if [[ "$expected_commit" != "${vscodeCommit}" ]]; then
              echo "VS Code client commit $expected_commit != server rev ${vscodeCommit}" >&2
              exit 1
            fi
            mkdir -p work/vscode-server-linux-x64
            cp -r ${pkgs.vscode.vscodeServer}/. work/vscode-server-linux-x64/
            find work/vscode-server-linux-x64 -type d -exec chmod 0755 {} +
            find work/vscode-server-linux-x64 -type f -perm /0111 -exec chmod 0755 {} +
            find work/vscode-server-linux-x64 -type f ! -perm /0111 -exec chmod 0644 {} +
            tar --owner=0 --group=0 --numeric-owner -czf "$out" -C work vscode-server-linux-x64
          '';

      vscodeWithRemoteContainers = pkgs.vscode-with-extensions.override {
        vscodeExtensions = [
          pkgs.vscode-extensions.ms-vscode-remote.remote-containers
        ];
      };

      userSettingsJson = builtins.toJSON {
        "remote.serverDownloadBaseUrl" = "http://127.0.0.1:9/offline-cache-only";
        "remote.serverDownloadFolder" = serverDownloadFolder;
        "dev.containers.mountWaylandSocket" = true;
        "dev.containers.copyGitConfig" = false;
        "remote.autoForwardPorts" = false;
        "security.workspace.trust.enabled" = false;
        "workbench.startupEditor" = "none";
        "extensions.autoCheckUpdates" = false;
        "extensions.autoUpdate" = false;
        "extensions.ignoreRecommendations" = true;
        "update.mode" = "none";
        "telemetry.enableTelemetry" = false;
        "telemetry.telemetryLevel" = "off";
        "chat.disableAIFeatures" = true;
        "chat.commandCenter.enabled" = false;
        "chat.agent.enabled" = false;
        "window.titleBarStyle" = "custom";
      };

      swayConfig = pkgs.writeText "sway-editor-config" ''
        output * resolution 1920x1080 position 0,0
        seat * xcursor_theme default 24
        default_border pixel 2
        exec ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP
        exec systemctl --user start sway-ready.target
      '';

      playwrightPython = pkgs.python3.withPackages (p: [ p.playwright ]);
    in
    {
      nixpkgs.overlays = [ vscodeOverlay ];
      nixpkgs.config.allowUnfreePackages = [
        "vscode"
        "vscode-with-extensions"
        "vscode-extension-ms-vscode-remote-remote-containers"
      ];

      hardware.graphics.enable = true;
      services.dbus.enable = true;
      security.polkit.enable = true;
      programs.sway = {
        enable = true;
        wrapperFeatures.gtk = true;
        extraPackages = with pkgs; [
          swaybg
          wl-clipboard
          xwayland
        ];
      };

      services.greetd = {
        enable = true;
        settings.default_session = {
          command = "${pkgs.dbus}/bin/dbus-run-session ${pkgs.sway}/bin/sway --config ${swayConfig}";
          inherit user;
        };
      };

      systemd.user.targets.sway-ready = {
        description = "Sway Wayland compositor ready";
      };

      virtualisation.qemu.options = [
        "-cpu host"
        "-vga none -device virtio-gpu-pci,xres=1920,yres=1080"
      ];

      environment.variables = {
        WLR_RENDERER = "pixman";
        LIBGL_ALWAYS_SOFTWARE = "1";
        XDG_CURRENT_DESKTOP = "sway";
        XDG_SESSION_TYPE = "wayland";
      };

      fonts = {
        enableDefaultPackages = false;
        packages = with pkgs; [
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-color-emoji
          dejavu_fonts
        ];
      };

      users.groups.${user} = lib.mkIf (user != "users") {
        inherit gid;
      };

      users.users.${user} = {
        isNormalUser = true;
        inherit uid;
        group = lib.mkDefault (if user != "users" then user else "users");
        extraGroups = [
          "video"
          "render"
          "input"
          "wheel"
        ];
      };

      environment.systemPackages = [
        vscodeWithRemoteContainers
        playwrightPython
        pkgs.jq
        pkgs.procps
        pkgs.psmisc
      ];

      systemd.tmpfiles.rules = [
        "d ${homeDir}/.cache 0755 ${user} ${user} -"
        "d ${serverDownloadFolder} 0755 ${user} ${user} -"
        "d ${serverDownloadFolder}/${vscodeCommit} 0755 ${user} ${user} -"
        "C+ ${serverDownloadFolder}/${vscodeCommit}/vscode-server-linux-x64.tar.gz 0644 ${user} ${user} - ${vscodeServerArchive}"
        "d ${homeDir}/.config 0755 ${user} ${user} -"
        "d ${homeDir}/.config/Code 0755 ${user} ${user} -"
        "d ${homeDir}/.config/Code/User 0755 ${user} ${user} -"
        "C+ ${homeDir}/.config/Code/User/settings.json 0644 ${user} ${user} - ${pkgs.writeText "vscode-offline-settings.json" userSettingsJson}"
      ];
    };
in
{
  inherit
    mkTest
    mkContainerHostModule
    mkSwayEditorModule
    testingDir
    runtimePy
    guiPy
    vscodeCdpPy
    ;
  containerHostModule = mkContainerHostModule { };
  swayEditorModule = mkSwayEditorModule { };
}
