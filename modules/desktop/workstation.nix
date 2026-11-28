{
  config,
  lib,
  pkgs,
  userName ? null,
  ...
}:
let
  cfg = config.site.desktop;
  networkRulesEnabled =
    (config.site.network.dns.enable or false) || (config.site.network.singBox.enable or false);
  locker = import ../../nix/desktop-lock.nix { inherit pkgs; };
  userHome = config.home-manager.users.${userName};
  gtkSettings = {
    gtk-im-module = "fcitx";
    gtk-font-name = "${builtins.head config.fonts.fontconfig.defaultFonts.sansSerif} 10";
    gtk-cursor-theme-name = userHome.home.pointerCursor.name;
    gtk-cursor-theme-size = userHome.home.pointerCursor.size;
  };
  swayService = command: {
    wantedBy = [ "site-sway.target" ];
    partOf = [
      "site-sway.target"
      "graphical-session.target"
    ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=sway:X-Sway";
    serviceConfig = {
      ExecStart = command;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
  waylandSessionWrapper = pkgs.writeShellScript "wayland-session" ''
    . /etc/profile
    if [ -f ~/.profile ]; then
      source ~/.profile
    fi
    cd "$HOME"

    ${lib.optionalString config.services.displayManager.logToJournal ''
      if [ -z "''${_DID_SYSTEMD_CAT:-}" ]; then
        export _DID_SYSTEMD_CAT=1
        exec ${config.systemd.package}/bin/systemd-cat -t wayland-session "$0" "$@"
      fi
    ''}
    unset _DID_SYSTEMD_CAT

    mkdir -p "''${XDG_DATA_HOME:-$HOME/.local/share}"

    ${pkgs.systemd}/bin/systemctl --user import-environment DBUS_SESSION_BUS_ADDRESS XDG_SESSION_ID
    ${pkgs.systemd}/bin/systemctl --user daemon-reload
    ${pkgs.glib}/bin/gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ReloadConfig >/dev/null

    # The wrapper execs the selected session in-place, preserving its PID. Watch
    # that lifetime even when SDDM terminates it before the desktop can log out.
    ${pkgs.systemd}/bin/systemctl --user start "site-session-watch@$$.service" || exit 1

    case "''${XDG_CURRENT_DESKTOP:-}" in
      sway)
        unset GTK_IM_MODULE
        export XDG_CURRENT_DESKTOP=sway:X-Sway QT_IM_MODULE=fcitx
        ;;
      KDE)
        # KWin supplies the native input-method socket. Clear any module
        # overrides left in the shared user bus by a previous Sway session.
        unset GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE
        ${pkgs.systemd}/bin/systemctl --user unset-environment GTK_IM_MODULE QT_IM_MODULE SDL_IM_MODULE
        ${lib.optionalString (config.services.dbus.implementation == "dbus") ''
          ${pkgs.dbus}/bin/dbus-update-activation-environment GTK_IM_MODULE= QT_IM_MODULE= SDL_IM_MODULE=
        ''}
        ;;
    esac

    if [ -n "''${1:-}" ]; then
      eval exec "$@"
    else
      echo "error: missing Wayland session command" >&2
      exit 1
    fi
  '';
in
{
  imports = [
    ./displays.nix
    ./fonts.nix
    ./wallpaper.nix
  ];
  options.site.desktop = {
    enable = lib.mkEnableOption "Sway and Plasma Wayland workstation";
    sway.enable = lib.mkOption {
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
        assertion = config.site.home.enable;
        message = "Enabling site.desktop requires site.home.enable.";
      }
      {
        assertion = cfg.sway.enable || cfg.plasma.enable;
        message = "Enable at least one desktop session, or disable site.desktop entirely.";
      }
    ];
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
      settings.Theme = lib.mkIf cfg.plasma.enable {
        CursorTheme = "breeze_cursors";
        CursorSize = 24;
      };
      settings.Wayland.SessionCommand = toString waylandSessionWrapper;
    };
    services.displayManager.defaultSession = if cfg.sway.enable then "sway" else "plasma";
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
    programs.nm-applet.enable = config.networking.networkmanager.enable && cfg.sway.enable;
    systemd.user.services.nm-applet = lib.mkIf config.programs.nm-applet.enable {
      wantedBy = lib.mkForce [ "site-sway.target" ];
      partOf = [ "site-sway.target" ];
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
      extraConfig.pipewire."20-desktop-bell"."context.properties"."module.x11.bell" = false;
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
      "xdg/plasma-workspace/shutdown/site-background.sh" = lib.mkIf cfg.plasma.enable {
        mode = "0755";
        source = pkgs.writeShellScript "site-background-shutdown" ''
          set -eu
          # Plasma runs this after applications accept logout, before stopping
          # graphical-session.target with job mode "fail". Quiesce the trigger
          # before cancelling its outstanding oneshot start job.
          ${pkgs.systemd}/bin/systemctl --user stop desktop-health.timer
          ${pkgs.systemd}/bin/systemctl --user stop desktop-health.service
          ${lib.optionalString networkRulesEnabled ''
            ${pkgs.systemd}/bin/systemctl --user stop site-network-rules-notify.service
          ''}
        '';
      };
    };
    systemd.user.tmpfiles.rules = [
      "C %h/.config/gtk-2.0/gtkrc 0600 - - - ${config.environment.etc."gtk-2.0/gtkrc".source}"
    ];
    systemd.user.targets.site-sway = {
      bindsTo = [ "graphical-session.target" ];
      wants = [
        "graphical-session-pre.target"
        "xdg-desktop-autostart.target"
      ];
      after = [
        "graphical-session-pre.target"
        "graphical-session.target"
      ];
    };
    systemd.user.services = {
      "site-session-watch@" = {
        description = "Stop graphical services when the login session exits";
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${pkgs.util-linux}/bin/waitpid --exited %i";
          ExecStopPost = "${pkgs.systemd}/bin/systemctl --user --no-block stop graphical-session.target site-sway.target";
        };
      };
      desktop-health = {
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        unitConfig.Requisite = "graphical-session.target";
        serviceConfig = {
          Type = "oneshot";
          TimeoutStopSec = "5s";
          ExecStart = pkgs.writeShellScript "desktop-health" ''
            export PATH=${
              lib.makeBinPath [
                pkgs.systemd
                pkgs.libnotify
              ]
            }
            exec ${pkgs.python3}/bin/python3 ${../../scripts/desktop/health.py} \
              ${lib.optionalString (config.site.backup.enable or false) "--check-backup"} \
              ${lib.optionalString networkRulesEnabled "--check-network-rules"}
          '';
        };
      };
      site-network-rules-notify = lib.mkIf networkRulesEnabled {
        description = "Review downloaded network rules";
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        unitConfig.Requisite = "graphical-session.target";
        serviceConfig = {
          Type = "exec";
          KillSignal = "SIGINT";
          TimeoutStopSec = "5s";
          ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/desktop/network_rules.py} --notify-send ${pkgs.libnotify}/bin/notify-send --rofi ${userHome.programs.rofi.finalPackage}/bin/rofi --systemctl ${pkgs.systemd}/bin/systemctl";
        };
      };
      sway-session-watch = lib.mkIf cfg.sway.enable (
        (swayService "${pkgs.sway}/bin/swaymsg -m -t subscribe '[\"shutdown\"]'")
        // {
          serviceConfig = {
            ExecStart = "${pkgs.sway}/bin/swaymsg -m -t subscribe '[\"shutdown\"]'";
            ExecStopPost = "${pkgs.systemd}/bin/systemctl --user --no-block stop site-sway.target";
          };
        }
      );
      waybar = lib.mkIf cfg.sway.enable (
        swayService "${pkgs.waybar}/bin/waybar -c ${userHome.xdg.configFile."waybar/config".source} -s ${
          userHome.xdg.configFile."waybar/style.css".source
        }"
      );
      mako = lib.mkIf cfg.sway.enable (
        swayService "${pkgs.mako}/bin/mako --config ${userHome.xdg.configFile."mako/config".source}"
      );
      swayidle = lib.mkIf cfg.sway.enable (
        swayService "${pkgs.swayidle}/bin/swayidle -w timeout 60 '${locker}/bin/desktop-lock' lock '${locker}/bin/desktop-lock' before-sleep '${locker}/bin/desktop-lock'"
      );
      sway-polkit = lib.mkIf cfg.sway.enable (
        swayService "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1"
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
      pavucontrol
      libnotify
      wl-clipboard
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
