{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.desktop;
  wallpaper = import ../../nix/wallpaper.nix { inherit pkgs; };
  service = action: {
    description = "${action} desktop wallpaper";
    partOf = [
      "site-sway.target"
      "graphical-session.target"
    ];
    after = [
      "site-sway.target"
      "graphical-session.target"
      "systemd-tmpfiles-setup.service"
    ];
    unitConfig = lib.optionalAttrs (action != "apply") {
      Requisite = "graphical-session.target";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${wallpaper}/bin/site-wallpaper ${action}";
      TimeoutStartSec = if action == "fetch" then "5min" else "20s";
      TimeoutStopSec = "5s";
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
      UMask = "0077";
      RuntimeDirectory = "site-wallpaper";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      ReadWritePaths = [
        "%t/site-wallpaper"
        "%h/.local/state/site-wallpaper"
      ]
      ++ lib.optional (action == "fetch") "%h/Pictures/wallpaper";
      RestrictAddressFamilies = [
        "AF_UNIX"
      ]
      ++ lib.optionals (action == "fetch") [
        "AF_INET"
        "AF_INET6"
      ];
      InaccessiblePaths = [ config.site.storage.persistRoot ];
    }
    // (
      if action == "fetch" then
        {
          TemporaryFileSystem = "%h:ro";
          BindPaths = [
            "%h/Pictures/wallpaper"
            "%h/.local/state/site-wallpaper"
          ];
        }
      else
        {
          ProtectHome = "read-only";
        }
    )
    // lib.optionalAttrs (action != "apply") {
      ExecCondition = "${pkgs.systemd}/bin/systemctl --user is-active --quiet site-sway.target";
    };
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.sway.enable) {
    systemd.user.tmpfiles.rules = [
      "d %h/Pictures/wallpaper 0700 - - -"
      "d %h/.local/state/site-wallpaper 0700 - - -"
    ];
    systemd.user.services = {
      site-wallpaper = service "rotate";
      site-wallpaper-apply = service "apply";
      site-wallpaper-schedule = service "schedule";
      site-wallpaper-fetch = lib.recursiveUpdate (service "fetch") {
        serviceConfig.ExecStopPost = "${wallpaper}/bin/site-wallpaper schedule";
      };
    };
    systemd.user.timers = {
      site-wallpaper = {
        wantedBy = [ "site-sway.target" ];
        partOf = [
          "site-sway.target"
          "graphical-session.target"
        ];
        timerConfig = {
          OnActiveSec = "30min";
          OnUnitActiveSec = "30min";
        };
      };
      "site-wallpaper-fetch@" = {
        partOf = [
          "site-sway.target"
          "graphical-session.target"
        ];
        after = [ "graphical-session.target" ];
        unitConfig.Requisite = "graphical-session.target";
        timerConfig = {
          OnCalendar = "@%i";
          Unit = "site-wallpaper-fetch.service";
          AccuracySec = "1s";
          RemainAfterElapse = false;
        };
      };
    };
  };
}
