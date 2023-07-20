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
        position = 1;
        enable = true;
        settings = {
          format_up = "IPv6";
          format_down = "IPv6";
        };
      };

      "wireless _first_" = {
        position = 2;
        settings = {
          format_up = "🛜%quality";
          format_down = "🛜";
        };
      };

      "ethernet _first_" = {
        position = 3;
        settings = {
          format_up = "🖧";
          format_down = "🖧";
        };
      };

      load = {
        position = 4;
        settings = {
          format = "💪 %1min";
        };
      };

      "volume master" = {
        position = 5;
        settings = {
          format = "🔊 %volume";
          device = "default";
          mixer = "Master";
          mixer_idx = 0;
        };
      };

      # "disk /nix" = {
      #   position = 6;
      #   settings = {
      #     format = "/nix %avail";
      #   };
      # };

      "disk /persist" = {
        position = 6;
        settings = {
          format = "📁 %avail";
        };
      };

      "battery all" = {
        position = 7;
        settings = {
          # last_full_capacity = true;
          format = "%status %percentage %remaining %emptytime";
          format_down = "None";
          status_chr = "⚡CHR";
          status_bat = "🔋BAT";
          status_unk = "❓UNK";
          status_full = "😄FULL";
          path = "/sys/class/power_supply/BAT%d/uevent";
          low_threshold = 10;
        };
      };

      "tztime local" = {
        position = 8;
        settings = {
          format = "⏰%Y-%m-%d %H:%M:%S";
        };
      };

      "tztime CN" = {
        position = 9;
        settings = {
          format = "🇨🇳%H:%M";
          timezone = "Asia/Shanghai";
        };
      };
    };
  };
}
