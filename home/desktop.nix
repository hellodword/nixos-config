{
  config,
  nixosConfig,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = nixosConfig.site.desktop;
  c = import ../lib/palette.nix;
  sans = builtins.head nixosConfig.fonts.fontconfig.defaultFonts.sansSerif;
  mono = builtins.head nixosConfig.fonts.fontconfig.defaultFonts.monospace;
  fcitxThemes = inputs.catppuccin-fcitx5 + /src;
  tools = import ../nix/desktop-tools.nix {
    inherit pkgs;
    rofi = config.programs.rofi.finalPackage;
  };
  notificationActivation = pkgs.writeShellScript "activate-session-notifications" ''
    set -eu
    # Late notifications during logout must not resurrect graphical services.
    ${pkgs.systemd}/bin/systemctl --user is-active --quiet graphical-session.target
    # The user service directory wins over the three packages' competing
    # activation files. Keep ownership with the selected session's user unit.
    case ":''${XDG_CURRENT_DESKTOP:-}:" in
      *:sway:*) unit=mako.service ;;
      *:i3:*) unit=dunst.service ;;
      *:KDE:*) unit=plasma-plasmashell.service ;;
      *) exit 1 ;;
    esac
    ${pkgs.systemd}/bin/systemctl --user start --no-block "$unit"
    exec ${pkgs.glib}/bin/gdbus wait --session --timeout 30 org.freedesktop.Notifications
  '';
  start = pkgs.writeShellScript "start-wm-session" ''
    set -eu
    session="$1"
    case "$session" in
      sway)
        other=i3
        export XDG_CURRENT_DESKTOP=sway:X-Sway XDG_SESSION_TYPE=wayland
        unset I3SOCK
        unset GTK_IM_MODULE
        ${pkgs.systemd}/bin/systemctl --user unset-environment GTK_IM_MODULE
        ${lib.optionalString (nixosConfig.services.dbus.implementation == "dbus") ''
          ${pkgs.dbus}/bin/dbus-update-activation-environment GTK_IM_MODULE=
        ''}
        ${pkgs.systemd}/bin/systemctl --user unset-environment I3SOCK
        ${lib.optionalString (nixosConfig.services.dbus.implementation == "dbus") ''
          ${pkgs.dbus}/bin/dbus-update-activation-environment I3SOCK=
        ''}
        displayVars=(DISPLAY WAYLAND_DISPLAY SWAYSOCK)
        imVars=(QT_IM_MODULE)
        ;;
      i3)
        other=sway
        export XDG_CURRENT_DESKTOP=i3 XDG_SESSION_TYPE=x11
        unset WAYLAND_DISPLAY SWAYSOCK
        ${pkgs.systemd}/bin/systemctl --user unset-environment WAYLAND_DISPLAY SWAYSOCK
        ${lib.optionalString (nixosConfig.services.dbus.implementation == "dbus") ''
          ${pkgs.dbus}/bin/dbus-update-activation-environment WAYLAND_DISPLAY= SWAYSOCK=
        ''}
        displayVars=(DISPLAY I3SOCK)
        imVars=(GTK_IM_MODULE QT_IM_MODULE)
        ;;
      *) exit 2 ;;
    esac
    ${pkgs.systemd}/bin/systemctl --user stop "site-$other.target"
    # dbus-broker uses systemd's environment and forwards activation updates
    # back to it. Only dbus-daemon needs separate stale variables cleared above.
    if [ -n "''${PAM_KWALLET5_LOGIN:-}" ]; then
      ${pkgs.systemd}/bin/systemctl --user import-environment PAM_KWALLET5_LOGIN
    fi
    ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd \
      "''${displayVars[@]}" XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID XDG_VTNR \
      "''${imVars[@]}"
    if [ -n "''${PAM_KWALLET5_LOGIN:-}" ]; then
      ${pkgs.systemd}/bin/systemctl --user start --wait plasma-kwallet-pam.service
      ${pkgs.glib}/bin/gdbus wait --session --timeout 30 org.freedesktop.secrets
    fi
    ${pkgs.systemd}/bin/systemctl --user start "site-$session.target"
  '';
  common = ''
    set $mod Mod4
    font pango:JetBrainsMono Nerd Font, Noto Sans CJK SC 10
    floating_modifier $mod
    default_border pixel 2
    workspace_layout tabbed
    default_orientation vertical
    title_align center
    for_window [class="(?i)^(mpv|feh|Emulator|Waydroid)$"] floating enable
    gaps inner 0
    gaps outer 0
    client.focused ${c.accent} ${c.surface} ${c.text} ${c.accent} ${c.accent}
    client.unfocused ${c.surface} ${c.background} ${c.muted} ${c.surface} ${c.surface}
    client.urgent ${c.urgent} ${c.urgent} ${c.background} ${c.urgent} ${c.urgent}
    bindsym $mod+Return exec ${pkgs.kitty}/bin/kitty
    bindsym $mod+d exec ${config.programs.rofi.finalPackage}/bin/rofi -show drun
    bindsym $mod+Shift+d exec ${config.programs.rofi.finalPackage}/bin/rofi -show run
    bindsym $mod+Shift+p exec ${tools.power}/bin/desktop-power
    bindsym $mod+Shift+q kill
    bindsym $mod+f fullscreen toggle
    bindsym $mod+Shift+space floating toggle
    bindsym $mod+Shift+c reload
    bindsym $mod+h focus left
    bindsym $mod+j focus down
    bindsym $mod+k focus up
    bindsym $mod+l focus right
    bindsym $mod+Shift+h move left
    bindsym $mod+Shift+j move down
    bindsym $mod+Shift+k move up
    bindsym $mod+Shift+l move right
    bindsym $mod+Ctrl+Left move workspace to output left
    bindsym $mod+Ctrl+Right move workspace to output right
    bindsym $mod+Ctrl+Shift+Left move container to output left
    bindsym $mod+Ctrl+Shift+Right move container to output right
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+e layout toggle split
    bindsym $mod+a focus parent
    bindsym $mod+minus scratchpad show
    bindsym $mod+Shift+minus move scratchpad
    bindsym $mod+r mode "resize"
    mode "resize" {
      bindsym h resize shrink width 10 px or 10 ppt
      bindsym j resize grow height 10 px or 10 ppt
      bindsym k resize shrink height 10 px or 10 ppt
      bindsym l resize grow width 10 px or 10 ppt
      bindsym Left resize shrink width 10 px or 10 ppt
      bindsym Down resize grow height 10 px or 10 ppt
      bindsym Up resize shrink height 10 px or 10 ppt
      bindsym Right resize grow width 10 px or 10 ppt
      bindsym Return mode "default"
      bindsym Escape mode "default"
      bindsym $mod+r mode "default"
    }
    bindsym $mod+Left focus left
    bindsym $mod+Down focus down
    bindsym $mod+Up focus up
    bindsym $mod+Right focus right
    bindsym $mod+Shift+Left move left
    bindsym $mod+Shift+Down move down
    bindsym $mod+Shift+Up move up
    bindsym $mod+Shift+Right move right
    bindsym $mod+b split h
    bindsym $mod+v split v
    bindsym XF86AudioRaiseVolume exec ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
    bindsym XF86AudioLowerVolume exec ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bindsym XF86AudioMute exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindsym XF86MonBrightnessUp exec ${pkgs.brightnessctl}/bin/brightnessctl set +5%
    bindsym XF86MonBrightnessDown exec ${pkgs.brightnessctl}/bin/brightnessctl set 5%-
  ''
  + lib.concatMapStrings (n: ''
    bindsym $mod+${toString n} workspace number ${toString n}
    bindsym $mod+Shift+${toString n} move container to workspace number ${toString n}
  '') (lib.range 1 9);
  swayConfig = pkgs.writeText "sway-config" (
    common
    + ''
        output * bg ${c.background} solid_color
        for_window [app_id="(?i)^(mpv|feh|Emulator|Waydroid)$"] floating enable
        bindsym $mod+p exec ${pkgs.systemd}/bin/systemctl --user start wdisplays.service
        input type:touchpad {
          tap ${if nixosConfig.services.libinput.touchpad.tapping then "enabled" else "disabled"}
          natural_scroll ${
            if nixosConfig.services.libinput.touchpad.naturalScrolling then "enabled" else "disabled"
          }
          scroll_method two_finger
          dwt enabled
        }
        exec ${start} sway
        exec_always ${pkgs.systemd}/bin/systemctl --user is-active --quiet site-sway.target && ${pkgs.systemd}/bin/systemctl --user --no-block start site-wallpaper-apply.service
        bindsym $mod+Shift+e exec ${pkgs.sway}/bin/swaynag -t warning -m 'End this session?' -B 'Log out' '${pkgs.sway}/bin/swaymsg exit'
        bindsym $mod+semicolon exec ${tools.lock}/bin/desktop-lock sway
        bindsym Print exec ${tools.shot}/bin/desktop-shot area copy
      bindsym Shift+Print exec ${tools.shot}/bin/desktop-shot screen copy
      bindsym $mod+Print exec ${tools.shot}/bin/desktop-shot area save
      bindsym $mod+Shift+Print exec ${tools.shot}/bin/desktop-shot screen save
      bindsym $mod+Shift+s exec ${tools.shot}/bin/desktop-shot area edit
    ''
  );
  i3Config = pkgs.writeText "i3-config" (
    common
    + ''
      exec ${start} i3
      exec_always --no-startup-id ${pkgs.systemd}/bin/systemctl --user is-active --quiet site-i3.target && ${pkgs.systemd}/bin/systemctl --user --no-block start site-wallpaper-apply.service
      bindsym $mod+p exec ${pkgs.arandr}/bin/arandr
      exec --no-startup-id ${pkgs.xsetroot}/bin/xsetroot -solid '${c.background}'
      bindsym $mod+Shift+e exec ${pkgs.i3}/bin/i3-nagbar -t warning -m 'End this session?' -B 'Log out' '${pkgs.i3}/bin/i3-msg exit'
      bindsym $mod+semicolon exec ${tools.lock}/bin/desktop-lock i3
      exec --no-startup-id ${pkgs.xset}/bin/xset s 60 0
      bindsym Print exec ${tools.shot}/bin/desktop-shot area copy
      bindsym Shift+Print exec ${tools.shot}/bin/desktop-shot screen copy
      bindsym $mod+Print exec ${tools.shot}/bin/desktop-shot area save
      bindsym $mod+Shift+Print exec ${tools.shot}/bin/desktop-shot screen save
      bindsym $mod+Shift+s exec ${tools.shot}/bin/desktop-shot area edit
      bar {
        status_command ${pkgs.i3status-rust}/bin/i3status-rs ${
          config.xdg.configFile."i3status-rust/config-default.toml".source
        }
        position top
        height 24
        workspace_min_width 40
        colors {
          background ${c.background}
          statusline ${c.text}
          focused_workspace ${c.accent} ${c.accent} ${c.background}
        }
      }
    ''
  );

in
{
  config = lib.mkIf cfg.enable {
    xdg.desktopEntries."network.cycles.wdisplays" = lib.mkIf cfg.sway.enable {
      name = "Displays";
      comment = "Arrange displays and save the current combination";
      exec = "${pkgs.systemd}/bin/systemctl --user start wdisplays.service";
      icon = "video-display";
      categories = [
        "Settings"
        "HardwareSettings"
      ];
      settings.OnlyShowIn = "X-Sway;";
      terminal = false;
    };
    xdg.desktopEntries."io.github.slgobinath.SafeEyes" = lib.mkIf nixosConfig.services.safeeyes.enable {
      name = "Safe Eyes";
      comment = "Configure break reminders";
      exec = "safeeyes --settings";
      icon = "io.github.slgobinath.SafeEyes";
      categories = [ "Utility" ];
      terminal = false;
    };
    xdg.configFile."autostart/io.github.slgobinath.SafeEyes.desktop" =
      lib.mkIf nixosConfig.services.safeeyes.enable
        {
          text = ''
            [Desktop Entry]
            Type=Application
            Name=Safe Eyes
            Hidden=true
          '';
        };
    xdg.dataFile."dbus-1/services/org.freedesktop.secrets.service".text = ''
      [D-BUS Service]
      Name=org.freedesktop.secrets
      Exec=${pkgs.kdePackages.kwallet}/bin/ksecretd
    '';

    home.sessionVariables = {
      TERMINAL = "kitty";
      GTK2_RC_FILES = "${config.xdg.configHome}/gtk-2.0/gtkrc";
    };
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
      setSessionVariables = false;
    };
    home.pointerCursor = {
      enable = true;
      package = pkgs.kdePackages.breeze;
      name = "breeze_cursors";
      size = 24;
      x11.enable = true;
    };
    dconf.settings."org/gnome/desktop/interface" = {
      font-name = "${sans} 10";
      document-font-name = "${sans} 10";
      monospace-font-name = "${mono} 11";
      cursor-theme = config.home.pointerCursor.name;
      cursor-size = config.home.pointerCursor.size;
    };
    programs.plasma = lib.mkIf cfg.plasma.enable {
      enable = true;
      overrideConfig = false;
      configFile."baloofilerc"."Basic Settings"."Indexing-Enabled" = false;
      kscreenlocker = {
        autoLock = true;
        timeout = 1;
        lockOnResume = true;
        passwordRequired = true;
        passwordRequiredDelay = 0;
      };
    };
    programs.kitty = {
      enable = true;
      keybindings = {
        "kitty_mod+n" = "new_os_window_with_cwd";
        "kitty_mod+t" = "new_tab_with_cwd";
      };
      font = {
        name = mono;
        size = 12.5;
      };
      settings = {
        window_padding_width = 0;
        background = c.background;
        foreground = c.text;
        selection_background = c.accent;
        selection_foreground = c.background;
        enable_audio_bell = false;
        confirm_os_window_close = 1;
        color0 = "#45475a";
        color1 = c.urgent;
        color2 = c.green;
        color3 = "#f9e2af";
        color4 = c.accent;
        color5 = "#f5c2e7";
        color6 = "#94e2d5";
        color7 = "#bac2de";
        color8 = "#585b70";
        color9 = c.urgent;
        color10 = c.green;
        color11 = "#f9e2af";
        color12 = c.accent;
        color13 = "#f5c2e7";
        color14 = "#94e2d5";
        color15 = "#a6adc8";
      };
    };
    programs.rofi = {
      package = pkgs.rofi;
      enable = true;
      settings.terminal = "${pkgs.kitty}/bin/kitty";
      settings.font = "${sans} 11";
      plugins = [
        pkgs.rofi-calc
        pkgs.rofi-emoji
      ];
      settings = {
        modi = "drun,run,calc,emoji";
        show-icons = true;
        calc-command = "${tools.copy}/bin/desktop-copy '{result}'";
        emoji-mode = "copy";
      };
    };
    xdg.configFile = {
      "sway/config" = lib.mkIf cfg.sway.enable { source = swayConfig; };
      "i3/config" = lib.mkIf cfg.i3.enable { source = i3Config; };
      # Display events belong to the i3 session service; XDG overrides keep
      # the upstream package reusable without competing autostart processes.
      "autostart/autorandr.desktop" = lib.mkIf cfg.i3.enable {
        text = ''
          [Desktop Entry]
          Type=Application
          Name=Autorandr
          Hidden=true
        '';
      };
      "autostart/autorandr-kde.desktop" = lib.mkIf cfg.i3.enable {
        text = ''
          [Desktop Entry]
          Type=Application
          Name=Autorandr KDE
          Hidden=true
        '';
      };
      "autostart/org.fcitx.Fcitx5.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Name=Fcitx 5
        Exec=${nixosConfig.i18n.inputMethod.package}/bin/fcitx5
        OnlyShowIn=sway;i3;
        NoDisplay=true
      '';
      "mako/config".text =
        "font=${sans} 11\nbackground-color=${c.surface}\ntext-color=${c.text}\nborder-color=${c.accent}\nborder-size=2\nborder-radius=8\ndefault-timeout=8000\n[urgency=critical]\nbackground-color=${c.urgent}\ntext-color=${c.background}\ndefault-timeout=0\n";
      "dunst/dunstrc".text = ''
        [global]
        font = ${sans} 11
        width = 320
        origin = top-right
        offset = (10, 42)
        padding = 10
        horizontal_padding = 12
        frame_width = 2
        frame_color = "${c.accent}"
        corner_radius = 8
        [urgency_low]
        background = "${c.surface}"
        foreground = "${c.text}"
        timeout = 8
        [urgency_normal]
        background = "${c.surface}"
        foreground = "${c.text}"
        timeout = 8
        [urgency_critical]
        background = "${c.urgent}"
        foreground = "${c.background}"
        timeout = 0
      '';
    };
    xdg.dataFile = {
      "fcitx5/themes" = {
        source = fcitxThemes;
        recursive = true;
      };
      "dbus-1/services/org.freedesktop.Notifications.service".text = ''
        [D-BUS Service]
        Name=org.freedesktop.Notifications
        Exec=${notificationActivation}
      '';
    };
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "application/pdf" = [ "org.kde.okular.desktop" ];
        "inode/directory" = [ "org.kde.dolphin.desktop" ];
      };
    };
    home.packages = builtins.attrValues tools;
  };
  imports = [ ./status-bars.nix ];
}
