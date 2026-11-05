{
  lib,
  pkgs,
  nixosConfig,
  ...
}:
let
  cfg = nixosConfig.site.desktop;
  c = import ../lib/palette.nix;
  sans = builtins.head nixosConfig.fonts.fontconfig.defaultFonts.sansSerif;
  tools = import ../nix/desktop-tools.nix { inherit pkgs; };
in
{
  config = lib.mkIf cfg.enable {
    programs.waybar = lib.mkIf cfg.sway.enable {
      enable = true;
      systemd.enable = false;
      settings.main = {
        layer = "top";
        height = 32;
        spacing = 12;
        modules-left = [
          "sway/workspaces"
          "sway/mode"
          "sway/scratchpad"
          "sway/window"
        ];
        modules-center = [
          "clock#utc"
          "clock#cn"
        ];
        modules-right = [
          "idle_inhibitor"
          "cpu"
          "memory"
          "disk"
          "disk#root"
          "custom/failed"
          "network"
          "custom/tailscale"
          "pulseaudio"
          "backlight"
          "temperature"
          "battery"
          "tray"
        ];
        cpu.format = "CPU {usage}%";
        "sway/window" = {
          format = "{title}";
          max-length = 35;
          separate-outputs = true;
        };
        "custom/failed" = {
          exec = "${pkgs.python3}/bin/python3 ${../scripts/desktop/health.py} --status";
          interval = 10;
        };
        memory.format = "RAM {percentage}%";
        disk = {
          path = nixosConfig.site.storage.persistRoot;
          format = "Disk {percentage_used}%";
        };
        "disk#root" = {
          path = "/";
          format = "Root {percentage_used}%";
        };
        network = {
          format-wifi = "Wi-Fi {signalStrength}%";
          format-ethernet = "LAN";
          format-disconnected = "Offline";
        };
        "custom/tailscale" = {
          exec = "${tools.tailscale}/bin/desktop-tailscale --waybar";
          return-type = "json";
          interval = 10;
        };
        pulseaudio = {
          format = "Audio {volume}%";
          on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
        };
        backlight.format = "Light {percent}%";
        temperature.format = "{temperatureC}°C";
        battery = {
          format = "Battery {capacity}% ↓";
          format-charging = "Battery {capacity}% ↑";
          format-full = "Battery {capacity}% Full";
          format-plugged = "Battery {capacity}% AC";
          states = {
            warning = 60;
            critical = 50;
          };
        };
        "clock#utc" = {
          timezone = "UTC";
          format = "{:%m-%d %H:%M UTC}";
        };
        "clock#cn" = {
          timezone = "Asia/Shanghai";
          format = "{:%H:%M CN}";
        };
        idle_inhibitor.format = "{status}";
      };
      style = ''
        * { font-family: "${sans}", sans-serif; font-size: 13px; border: none; }
        window#waybar { background: ${c.background}; color: ${c.text}; }
        #workspaces button { color: ${c.muted}; padding: 0 12px; }
        #workspaces button.focused { background: ${c.accent}; color: ${c.background}; border-radius: 5px; }
        #workspaces button.urgent, #battery.critical { background: ${c.urgent}; color: ${c.background}; }
        #tray { margin-right: 14px; } #battery.warning { color: ${c.urgent}; }
      '';
    };
    programs.i3status-rust = lib.mkIf cfg.i3.enable {
      enable = true;
      bars.default = {
        theme = "ctp-mocha";
        icons = "material-nf";
        blocks = [
          {
            block = "focused_window";
            driver = "sway_ipc";
            format = " $title.str(max_w:35) |";
          }
          {
            block = "cpu";
            format = " CPU $utilization ";
          }
          {
            block = "memory";
            format = " RAM $mem_used_percents ";
          }
          {
            block = "disk_space";
            path = nixosConfig.site.storage.persistRoot;
            info_type = "used";
            format = " Disk $percentage ";
          }
          {
            block = "net";
            format = " $icon {$ssid|$device} ";
          }
          {
            block = "disk_space";
            path = "/";
            info_type = "used";
            format = " Root $percentage ";
          }
          {
            block = "custom";
            command = "${pkgs.python3}/bin/python3 ${../scripts/desktop/health.py} --status";
            interval = 10;
          }
          {
            block = "custom";
            command = "${tools.tailscale}/bin/desktop-tailscale";
            interval = 10;
          }
          {
            block = "sound";
            click = [
              {
                button = "left";
                cmd = "${pkgs.pavucontrol}/bin/pavucontrol";
              }
            ];
          }
          {
            block = "backlight";
            missing_format = "";
          }
          {
            block = "temperature";
            format = " $icon $max ";
            if_command = ''for input in /sys/class/hwmon/hwmon*/temp*_input; do [ -r "$input" ] && exit 0; done; exit 1'';
          }
          {
            block = "battery";
            driver = "upower";
            format = " $icon $percentage ↓ ";
            charging_format = " $icon $percentage ↑ ";
            full_format = " $icon $percentage Full ";
            not_charging_format = " $icon $percentage AC ";
            warning = 60;
            critical = 50;
            missing_format = "";
          }
          {
            block = "time";
            timezone = "UTC";
            format = " $timestamp.datetime(f:'%m-%d %H:%M UTC') ";
          }
          {
            block = "time";
            timezone = "Asia/Shanghai";
            format = " $timestamp.datetime(f:'%H:%M CN') ";
          }
        ];
      };
    };
  };
}
