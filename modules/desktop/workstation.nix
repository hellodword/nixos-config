{
  config,
  lib,
  pkgs,
  userName,
  ...
}:
let
  cfg = config.site.desktop;
  userHome = config.home-manager.users.${userName};
  gtkSettings = {
    gtk-im-module = "fcitx";
    gtk-font-name = "${builtins.head config.fonts.fontconfig.defaultFonts.sansSerif} 10";
    gtk-cursor-theme-name = userHome.home.pointerCursor.name;
    gtk-cursor-theme-size = userHome.home.pointerCursor.size;
  };
  wmService = session: command: {
    wantedBy = [ "site-${session}.target" ];
    partOf = [
      "site-${session}.target"
      "graphical-session.target"
    ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=${
      if session == "sway" then "sway:X-Sway" else session
    }";
    serviceConfig = {
      ExecStart = command;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
  watcher =
    session: binary:
    (wmService session ("${binary} -m -t subscribe '[\"shutdown\"]'"))
    // {
      serviceConfig = {
        ExecStart = "${binary} -m -t subscribe '[\"shutdown\"]'";
        ExecStopPost = "${pkgs.systemd}/bin/systemctl --user --no-block stop site-${session}.target";
      };
    };
in
{
  imports = [ ./displays.nix ];
  options.site.desktop = {
    enable = lib.mkEnableOption "Sway, i3 and Plasma workstation";
    sway.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    i3.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    plasma.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.sway.enable || cfg.i3.enable || cfg.plasma.enable;
        message = "Enable at least one desktop session, or disable site.desktop entirely.";
      }
    ];
    services.xserver.enable = true;
    programs.i3lock.enable = cfg.i3.enable;
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
      theme = if cfg.plasma.enable then "breeze" else "";
      # SDDM otherwise uses its own Wayland script and skips sessionCommands.
      # Both protocols use the same session lifetime watcher.
      settings.Wayland.SessionCommand = toString config.services.displayManager.sessionData.wrapper;
    };
    services.displayManager.defaultSession =
      if cfg.sway.enable then
        "sway"
      else if cfg.plasma.enable then
        "plasma"
      else
        "none+i3";
    services.xserver.displayManager.sessionCommands = ''
      ${pkgs.systemd}/bin/systemctl --user daemon-reload
      ${pkgs.glib}/bin/gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ReloadConfig >/dev/null
      # The shared wrapper execs the selected session, preserving its PID. Watch that
      # lifetime even when SDDM terminates it before the desktop can log out.
      ${pkgs.systemd}/bin/systemctl --user start "site-session-watch@$$.service" || exit 1
      # The NixOS wrapper otherwise starts a fake graphical target before the
      # compositor has exported its display/IPC sockets. Mark only our WMs as
      # systemd-aware; their config starts the real session target when ready.
      case "''${XDG_CURRENT_DESKTOP:-}" in
        sway)
          unset I3SOCK
          unset GTK_IM_MODULE
          export XDG_CURRENT_DESKTOP=sway:X-Sway:X-NIXOS-SYSTEMD-AWARE QT_IM_MODULE=fcitx
          ;;
        i3|none+i3)
          unset WAYLAND_DISPLAY SWAYSOCK
          export XDG_CURRENT_DESKTOP=i3:X-NIXOS-SYSTEMD-AWARE GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx
          ;;
        KDE)
          # KWin supplies the native input-method socket. Clear any module
          # overrides left in the shared user bus by a previous WM session.
          unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE
          ${pkgs.systemd}/bin/systemctl --user unset-environment GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE
          ${lib.optionalString (config.services.dbus.implementation == "dbus") ''
            ${pkgs.dbus}/bin/dbus-update-activation-environment GTK_IM_MODULE= QT_IM_MODULE= SDL_IM_MODULE=
          ''}
          ;;
      esac
    '';
    services.xserver.windowManager.i3 = {
      enable = cfg.i3.enable;
      configFile = userHome.xdg.configFile."i3/config".source;
    };
    programs.sway = {
      enable = cfg.sway.enable;
      package = import ../../nix/sway.nix { inherit pkgs; };
      wrapperFeatures.gtk = true;
      extraOptions = [
        "--config"
        (toString userHome.xdg.configFile."sway/config".source)
      ];
      extraSessionCommands = ''
        unset GTK_IM_MODULE
        export XDG_CURRENT_DESKTOP=sway:X-Sway QT_IM_MODULE=fcitx
      '';
    };
    programs.nm-applet.enable =
      config.networking.networkmanager.enable && (cfg.sway.enable || cfg.i3.enable);
    systemd.user.services.nm-applet = lib.mkIf config.programs.nm-applet.enable {
      wantedBy = lib.mkForce (
        lib.optional cfg.sway.enable "site-sway.target" ++ lib.optional cfg.i3.enable "site-i3.target"
      );
      partOf = [
        "site-sway.target"
        "site-i3.target"
      ];
    };
    services.desktopManager.plasma6.enable = cfg.plasma.enable;
    services.dbus.enable = true;
    services.libinput.enable = true;
    services.libinput.touchpad = {
      tapping = true;
      scrollMethod = "twofinger";
      naturalScrolling = false;
      disableWhileTyping = true;
    };
    services.upower.enable = true;
    security.polkit.enable = true;
    security.rtkit.enable = true;
    security.pam.services.swaylock = lib.mkIf cfg.sway.enable { };
    services.pipewire = {
      enable = true;
      pulse.enable = true;
      alsa.enable = true;
      alsa.support32Bit = false;
      jack.enable = false;
      wireplumber.enable = true;
    };
    security.pam.services.login.kwallet.enable = true;
    security.pam.services.kde.kwallet.enable = true;
    services.dbus.packages = [ pkgs.kdePackages.kwallet ];
    systemd.packages = [
      pkgs.kdePackages.kwallet
      pkgs.kdePackages.kwallet-pam
    ];
    environment.etc."xdg/kwalletrc".text = ''
      [Wallet]
      Enabled=true
      Default Wallet=kdewallet
      Use One Wallet=true
      [org.freedesktop.secrets]
      apiEnabled=true
    '';
    i18n.inputMethod = {
      enable = true;
      type = "fcitx5";
      fcitx5.waylandFrontend = true;
      fcitx5.addons = with pkgs; [
        qt6Packages.fcitx5-chinese-addons
        fcitx5-gtk
      ];
    };
    # Kitty's X11 backend uses Fcitx's IBus-compatible D-Bus frontend.
    environment.variables.GLFW_IM_MODULE = "ibus";
    xdg.portal = {
      enable = true;
      wlr.enable = cfg.sway.enable;
      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.kdePackages.kwallet
      ];
      config = {
        sway = {
          default = [ "gtk" ];
          "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
          "org.freedesktop.impl.portal.Screenshot" = [ "wlr" ];
          "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };
        i3 = {
          default = [ "gtk" ];
          "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };
        KDE = {
          default = [
            "kde"
            "gtk"
          ];
          "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };
      };
    };
    environment.etc = {
      "gtk-2.0/gtkrc".text = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "${name}=${builtins.toJSON value}") gtkSettings
      );
      "xdg/gtk-3.0/settings.ini".text = lib.generators.toINI { } { Settings = gtkSettings; };
      "xdg/gtk-4.0/settings.ini".text = lib.generators.toINI { } { Settings = gtkSettings; };
      # Fcitx reads these defaults only when the user has no corresponding
      # configuration. Its writable profile, preferences and learned words
      # belong to the persisted user directories, never to store links.
      "xdg/fcitx5/profile".source = ../../data/fcitx5-profile;
      "xdg/fcitx5/config".source = ../../data/fcitx5-config;
      "xdg/fcitx5/conf/classicui.conf".text = ''
        Theme=catppuccin-mocha-mauve
        DarkTheme=catppuccin-mocha-mauve
      '';
      "xdg/kwinrc".text = ''
        [Wayland]
        InputMethod=${config.i18n.inputMethod.package}/share/applications/org.fcitx.Fcitx5.desktop
      '';
    };
    systemd.user.tmpfiles.rules = [
      "C %h/.config/gtk-2.0/gtkrc 0600 - - - ${config.environment.etc."gtk-2.0/gtkrc".source}"
    ];
    systemd.user.targets = lib.genAttrs [ "site-sway" "site-i3" ] (_: {
      bindsTo = [ "graphical-session.target" ];
      wants = [
        "graphical-session-pre.target"
        "xdg-desktop-autostart.target"
      ];
      after = [
        "graphical-session-pre.target"
        "graphical-session.target"
      ];
    });
    systemd.user.services = {
      "site-session-watch@" = {
        description = "Stop graphical services when the login session exits";
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${pkgs.util-linux}/bin/waitpid --exited %i";
          ExecStopPost = "${pkgs.systemd}/bin/systemctl --user --no-block stop graphical-session.target site-sway.target site-i3.target";
        };
      };
      desktop-health = {
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "desktop-health" ''
            export PATH=${
              lib.makeBinPath [
                pkgs.systemd
                pkgs.libnotify
              ]
            }
            export SITE_BACKUP_ENABLED=${if config.site.backup.enable or false then "1" else "0"}
            exec ${pkgs.python3}/bin/python3 ${../../scripts/desktop/health.py}
          '';
        };
      };
      sway-session-watch = lib.mkIf cfg.sway.enable (watcher "sway" "${pkgs.sway}/bin/swaymsg");
      i3-session-watch = lib.mkIf cfg.i3.enable (watcher "i3" "${pkgs.i3}/bin/i3-msg");
      waybar = lib.mkIf cfg.sway.enable (
        wmService "sway" "${pkgs.waybar}/bin/waybar -c ${
          userHome.xdg.configFile."waybar/config".source
        } -s ${userHome.xdg.configFile."waybar/style.css".source}"
      );
      mako = lib.mkIf cfg.sway.enable (
        wmService "sway" "${pkgs.mako}/bin/mako --config ${userHome.xdg.configFile."mako/config".source}"
      );
      dunst = lib.mkIf cfg.i3.enable (
        wmService "i3" "${pkgs.dunst}/bin/dunst -config ${userHome.xdg.configFile."dunst/dunstrc".source}"
      );
      snixembed = lib.mkIf cfg.i3.enable (
        lib.recursiveUpdate (wmService "i3" "${pkgs.snixembed}/bin/snixembed") {
          description = "Show StatusNotifierItem applications in the i3 tray";
          serviceConfig =
            (import ../../lib/desktop-service-hardening.nix {
              persistRoot = config.site.storage.persistRoot;
            })
            // {
              Type = "dbus";
              BusName = "org.kde.StatusNotifierWatcher";
              RuntimeDirectory = "snixembed";
              Environment = [ "XDG_CACHE_HOME=%t/snixembed" ];
            };
        }
      );
      swayidle = lib.mkIf cfg.sway.enable (
        wmService "sway" "${pkgs.swayidle}/bin/swayidle -w timeout 60 '${pkgs.swaylock}/bin/swaylock -f -c 1e1e2e' lock '${pkgs.swaylock}/bin/swaylock -f -c 1e1e2e' before-sleep '${pkgs.swaylock}/bin/swaylock -f -c 1e1e2e'"
      );
      xss-lock = lib.mkIf cfg.i3.enable (
        wmService "i3" "${pkgs.xss-lock}/bin/xss-lock --session \${XDG_SESSION_ID} --transfer-sleep-lock -- ${pkgs.i3lock}/bin/i3lock -n -c 1e1e2e"
      );
      sway-polkit = lib.mkIf cfg.sway.enable (
        wmService "sway" "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
      );
      i3-polkit = lib.mkIf cfg.i3.enable (
        wmService "i3" "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
      );
    };
    systemd.user.timers.desktop-health = {
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      timerConfig = {
        OnActiveSec = "30s";
        OnUnitInactiveSec = "1m";
      };
    };
    programs.dconf.enable = true;
    environment.etc."xdg/kdeglobals".text = ''
      [General]
      font=${builtins.head config.fonts.fontconfig.defaultFonts.sansSerif},10,-1,5,50,0,0,0,0,0
      fixed=${builtins.head config.fonts.fontconfig.defaultFonts.monospace},11,-1,5,50,0,0,0,0,0
    '';
    environment.systemPackages = with pkgs; [
      waybar
      mako
      dunst
      pavucontrol
      libnotify
      wl-clipboard
      xclip
      brightnessctl
      kdePackages.kwallet
      kdePackages.kwalletmanager
      kdePackages.dolphin
      kdePackages.okular
      kdePackages.breeze-icons
      adwaita-icon-theme
    ];
  };
}
