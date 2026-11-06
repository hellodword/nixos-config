{
  lib,
  pkgs,
  nixosConfig,
  ...
}:
let
  cfg = nixosConfig.site.desktop;
  sans = builtins.head nixosConfig.fonts.fontconfig.defaultFonts.sansSerif;
  tools = import ../nix/desktop-tools.nix { inherit pkgs; };
  localTimeZone = lib.optionalAttrs (nixosConfig.time.timeZone != null) {
    timezone = nixosConfig.time.timeZone;
  };
in
{
  config = lib.mkIf cfg.enable {
    programs.waybar = lib.mkIf cfg.sway.enable {
      enable = true;
      systemd.enable = false;
      settings.main = {
        layer = "top";
        height = 24;
        spacing = 4;
        modules-left = [
          "sway/workspaces"
          "sway/mode"
          "sway/scratchpad"
        ];
        modules-center = [ "sway/window" ];
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
          "clock#local"
          "clock#cn"
          "tray"
        ];
        cpu.format = " {usage}%";
        "sway/window" = {
          format = "{title}";
          max-length = 35;
          separate-outputs = true;
        };
        "custom/failed" = {
          exec = "${pkgs.python3}/bin/python3 ${../scripts/desktop/health.py} --status";
          interval = 10;
        };
        memory.format = " {percentage}%";
        disk = {
          path = nixosConfig.site.storage.persistRoot;
          format = " {used}/{total}";
          tooltip-format = "Persistent storage: {percentage_used}% used";
        };
        "disk#root" = {
          path = "/";
          format = "/ {used}/{total}";
          tooltip-format = "Root tmpfs: {percentage_used}% used";
        };
        network = {
          format-wifi = " {signalStrength}%";
          format-ethernet = "";
          format-disconnected = "Disconnected";
        };
        "custom/tailscale" = {
          exec = "${tools.tailscale}/bin/desktop-tailscale --waybar";
          return-type = "json";
          interval = 10;
        };
        pulseaudio = {
          format = " {volume}%";
          format-muted = "";
          on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
        };
        backlight.format = " {percent}%";
        temperature.format = "{temperatureC}°C";
        battery = {
          format = "{icon} {capacity}%";
          format-icons = [
            ""
            ""
            ""
            ""
            ""
          ];
          format-charging = " {capacity}%";
          format-full = " {capacity}%";
          format-plugged = " {capacity}%";
          states = {
            warning = 60;
            critical = 50;
          };
        };
        "clock#local" = localTimeZone // {
          format = "{:%m-%d %H:%M %Z}";
        };
        "clock#cn" = {
          timezone = "Asia/Shanghai";
          format = "{:%H:%M CN}";
        };
        idle_inhibitor = {
          format = "{icon}";
          format-icons = {
            activated = "";
            deactivated = "";
          };
          tooltip-format-activated = "保持活动：点击恢复一分钟自动锁屏";
          tooltip-format-deactivated = "自动锁屏：点击保持活动";
        };
      };
      style = ''
        * { font-family: "${sans}", "Noto Sans CJK SC", "Symbols Nerd Font", sans-serif; font-size: 13px; border: none; min-height: 0; }
        window#waybar { background: #2b303b; color: #ffffff; }
        button { border-radius: 0; padding: 0; }
        #workspaces button { color: #ffffff; padding: 0 5px; }
        #workspaces button.focused { background: #64727d; box-shadow: inset 0 -2px #ffffff; }
        #workspaces button.urgent { background: #b91c1c; }
        #window { margin: 0 4px; }
        #cpu, #memory, #disk, #network, #custom-tailscale, #custom-failed,
        #pulseaudio, #backlight, #temperature, #battery, #clock, #tray,
        #idle_inhibitor, #mode { padding: 0 8px; }
        #cpu { background: #2ecc71; color: #101820; }
        #memory { background: #7d3c98; }
        #disk { background: #874000; }
        #network, #custom-tailscale, #tray { background: #21618c; }
        #pulseaudio { background: #f1c40f; color: #101820; }
        #backlight { background: #90b1b1; color: #101820; }
        #temperature { background: #f0932b; color: #101820; }
        #battery { background: #ffffff; color: #101820; }
        #battery.warning { background: #f1c40f; color: #101820; }
        #battery.critical, #network.disconnected, #temperature.critical { background: #b91c1c; color: #ffffff; }
        #battery.charging, #battery.plugged { background: #187a45; color: #ffffff; }
        #clock, #mode { background: #45525e; }
        #idle_inhibitor { background: #2d3436; }
        #idle_inhibitor.activated { background: #ecf0f1; color: #202629; }
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
          (
            localTimeZone
            // {
              block = "time";
              format = " $timestamp.datetime(f:'%m-%d %H:%M %Z') ";
            }
          )
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
