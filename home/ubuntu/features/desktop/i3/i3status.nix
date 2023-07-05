{ pkgs, ... }:

{
  home.packages = with pkgs; [
    i3status # gives you the default i3 status bar
    i3blocks #if you are planning on using i3blocks over i3status
  ];


  xsession.windowManager.i3.config.bars = [
    {
      position = "top";
      statusCommand = "i3status";
      extraConfig = ''
        bindsym button2 exec rofi -show power-menu -modi 'power-menu:rofi-power-menu --choices=shutdown/reboot/logout' -width 20 -lines 3 -font 'Jetbrains Mono 16'
      '';
    }
  ];

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

      "disk /persist" = {
        position = 65;
        settings = {
          format = "%avail";
        };
      };

      "battery all" = {
        position = 70;
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
