{ pkgs, config, lib, nixosConfig, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  X = nixosConfig.services.xserver.windowManager.i3.enable;
  bars = [{
    position = "top";
    statusCommand = "i3status";
    fonts = {
      names = [ "JetBrainsMono Nerd Font" ];
      style = "Bold Semi-Condensed";
      size = 10.0;
    };
  }];
  sway-inhibit-idle = pkgs.writeShellApplication {
    name = "sway-inhibit-idle";
    text = ''
      if [ "''$(${pkgs.sway}/bin/swaymsg -t get_tree | ${lib.getExe pkgs.jq} -r '.. | select(.inhibit_idle?) | .inhibit_idle' | ${pkgs.coreutils}/bin/wc -l)" -eq "0" ]; then
        ${pkgs.sway}/bin/swaymsg 'inhibit_idle focus'
        ${pkgs.sway}/bin/swaymsg bar bar-0 colors background '#5F5050'
      else
        ${pkgs.sway}/bin/swaymsg 'inhibit_idle none'
        ${pkgs.sway}/bin/swaymsg bar bar-0 colors background '#000000'
      fi
    '';
  };
  keybindings = {
    "${mod}+u" = "exec ${sway-inhibit-idle}/bin/sway-inhibit-idle";
  };
in
{
  home.packages = with pkgs; [
    i3status # gives you the default i3 status bar
    i3blocks #if you are planning on using i3blocks over i3status
  ];

  xsession.windowManager.i3.config.bars = (lib.optionals (X) bars);
  wayland.windowManager.sway.config.bars = (lib.optionals (!X) bars);

  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;

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
        position = 11;
        settings = {
          format_up = "🛜%quality";
          format_down = "🛜 🚫";
        };
      };

      "ethernet _first_" = {
        position = 21;
        settings = {
          format_up = "🖧";
          format_down = "🖧";
        };
      };

      "ethernet wgcf" = {
        enable = builtins.hasAttr "wgcf" nixosConfig.networking.wg-quick.interfaces;
        position = 22;
        settings = {
          format_up = "wgcf";
          format_down = "wgcf";
        };
      };

      # load = {
      #   position = 31;
      #   settings = {
      #     format = "💪 %1min";
      #   };
      # };

      "volume master" = {
        position = 31;
        settings = {
          format = "🔊 %volume";
          device = "default";
          mixer = "Master";
          mixer_idx = 0;
        };
      };

      # "disk /nix" = {
      #   position = 41;
      #   settings = {
      #     format = "/nix %avail";
      #   };
      # };

      "memory" = {
        position = 41;
        settings = {
          format = "%available";
        };
      };

      "disk /persist" = {
        position = 51;
        settings = {
          format = "📁 %avail";
        };
      };

      "battery all" = {
        position = 61;
        settings = {
          last_full_capacity = true; # not the design
          format = "%status %percentage";
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
        position = 71;
        settings = {
          format = "⏰ %m-%d %H:%M:%S";
        };
      };

      "tztime CN" = {
        position = 81;
        settings = {
          format = "🇨🇳 %H:%M";
          timezone = "Asia/Shanghai";
        };
      };
    };
  };
}
