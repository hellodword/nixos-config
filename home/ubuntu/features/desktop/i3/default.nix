{ pkgs, lib, config, persistPath, ... }:

let
  mod = "Mod4";
in
{

  # TODO split/refactor


  # home.file.".xinitrc".text = ''
  #   autorandr --change
  #   exec i3
  # '';

  # programs.bash.bashrcExtra = ''
  #   if [ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ]; then
  #     exec ${pkgs.systemd}/bin/systemd-cat -t i3 ${pkgs.xorg.xinit}/bin/startx
  #   fi
  # '';

  imports = [
    ../common
    ./wallpaper.nix
  ];

  home.pointerCursor = {
    package = pkgs.phinger-cursors;
    name = "phinger-cursors-light";
    # Make cursor not tiny on HiDPI screens
    # size = 128;
    x11.enable = true;
  };

  home.packages = with pkgs; [
    rofi
    rofi-power-menu
    deadd-notification-center
    libnotify
    alsa-utils
    brightnessctl

    dmenu
    networkmanager_dmenu

    dmenu #application launcher most people use
    i3status # gives you the default i3 status bar
    i3lock #default i3 screen locker
    i3blocks #if you are planning on using i3blocks over i3status
  ];

  xdg.configFile."deadd" = {
    source = ./deadd;
    recursive = true;
    force = true;
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      # 使用新的 rimeDataPkgs 的时候要把文件清空
      ".config/ibus/rime"
      ".local/share/fcitx5/rime"
    ];
  };

  i18n.inputMethod = {
    enabled = "fcitx5";
    # fcitx.engines = with pkgs.fcitx-engines; [ rime ];
    # fcitx5.enableRimeData = true;
    fcitx5.addons = with pkgs; [
      (fcitx5-rime.override {
        rimeDataPkgs = [ pkgs.rime-ice ];
      })
    ];
  };

  xdg.configFile."fcitx5" = {
    source = ./fcitx5;
    recursive = true;
    # https://github.com/nix-community/home-manager/issues/1213#issuecomment-626240819
    force = true;
  };

  xsession = {
    enable = true;
    # for docker show GUI
    initExtra = ''
      ${pkgs.xorg.xhost}/bin/xhost local:
    '';
  };

  # for xrdp
  home.file.".xinitrc" = {
    text = ''
      ${pkgs.xorg.xhost}/bin/xhost local:
    '';
  };

  xsession.windowManager.i3 = {
    enable = true;
    package = pkgs.i3;
    extraConfig = ''
      title_align center
      default_orientation vertical
    '';
    config = {
      modifier = mod;
      terminal = "alacritty";
      # 生成配置后 ws10 会排在第一行，导致默认在 ws10
      defaultWorkspace = "workspace number 1";
      workspaceLayout = "tabbed";

      fonts = {
        names = [ "Jetbrains Mono" ];
        size = 10.0;
      };

      startup = [
        {
          command = "deadd-notification-center &";
          always = true;
          notification = false;
          workspace = null;
        }
        {
          command = "env XMODIFIERS=@im=fcitx QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx fcitx5 -d";
          always = true;
          notification = false;
          workspace = null;
        }
      ];

      keybindings = lib.mkOptionDefault {
        # 输入法切换冲突
        "${mod}+space" = null;
        "${mod}+d" = "exec rofi -modi drun -show drun -drun-show-actions -font 'Jetbrains Mono 16'";
        "${mod}+Shift+d" = "exec rofi -show run -font 'Jetbrains Mono 16'";
        "${mod}+Shift+p" = "exec rofi -show power-menu -modi 'power-menu:rofi-power-menu --choices=shutdown/reboot/logout' -width 20 -lines 3 -font 'Jetbrains Mono 16'";
        "${mod}+z" = "exec kill -s USR1 $(pidof deadd-notification-center)";
        "${mod}+semicolon" = "exec i3lock -c 01544A -n";
        # https://github.com/Th0rgal/horus-nix-home/blob/200c746e2baf5a299ad99756ed32e09a05bcbc1c/configs/i3.nix#L20
        "XF86AudioMute" = "exec amixer set Master toggle";
        "XF86AudioLowerVolume" = "exec amixer set Master 4%-";
        "XF86AudioRaiseVolume" = "exec amixer set Master 4%+";
        "XF86MonBrightnessDown" = "exec brightnessctl set 4%-";
        "XF86MonBrightnessUp" = "exec brightnessctl set 4%+";
        "Print" = if config.services.flameshot.enable then "exec flameshot gui" else null;
      };

      bars = [
        {
          position = "top";
          statusCommand = "i3status";
          extraConfig = ''
            bindsym button2 exec rofi -show power-menu -modi 'power-menu:rofi-power-menu --choices=shutdown/reboot/logout' -width 20 -lines 3 -font 'Jetbrains Mono 16'
          '';
        }
      ];
    };
  };

  # https://github.com/xtruder/nix-profiles/blob/6f9527124187af7e3d0efaa835712fb08df80fc2/home-manager/profiles/i3status.nix#L7
  programs.i3status = {
    enable = true;
    enableDefault = false;
    general = {
      output_format = "i3bar";
      colors = true;
      interval = 5;
    };

    modules = {
      ipv6 = {
        position = 10;
        enable = true;
      };

      "wireless _first_" = {
        position = 20;
        settings = {
          format_up = "W: (%quality)";
          format_down = "W: down";
        };
      };

      "ethernet _first_" = {
        position = 30;
        settings = {
          format_up = "E: up";
          format_down = "E: down";
        };
      };

      load = {
        position = 40;
        settings = {
          format = "↺ %1min";
        };
      };

      "volume master" = {
        position = 50;
        settings = {
          format = "♪ %volume";
          device = "default";
          mixer = "Master";
          mixer_idx = 0;
        };
      };

      "disk /nix" = {
        position = 60;
        settings = {
          format = "%avail";
        };
      };

      "battery all" = {
        position = 70;
        enable = lib.mkDefault false;
        settings = {
          format = "%status %percentage %remaining";
          low_threshold = 10;
          last_full_capacity = true;
        };
      };

      "tztime local" = {
        position = 80;
        settings = {
          format = "%Y-%m-%d ⌚ %H:%M:%S";
        };
      };

      "tztime CN" = {
        position = 90;
        settings = {
          format = "CN⌚ %H:%M";
          timezone = "Asia/Shanghai";
        };
      };
    };
  };
}
