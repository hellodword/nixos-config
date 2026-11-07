{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.desktop;
  wallpaper = import ../../nix/wallpaper.nix { inherit pkgs; };
  targets =
    lib.optional cfg.sway.enable "site-sway.target" ++ lib.optional cfg.i3.enable "site-i3.target";
  service = action: {
    description = "${action} desktop wallpaper";
    partOf = targets;
    after = targets ++ [
      "graphical-session.target"
      "systemd-tmpfiles-setup.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${wallpaper}/bin/site-wallpaper ${action}";
      TimeoutStartSec = if action == "fetch" then "5min" else "20s";
      TimeoutStopSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
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
    // lib.optionalAttrs (action != "apply") {
      ExecCondition = "${pkgs.systemd}/bin/systemctl --user is-active --quiet ${lib.concatStringsSep " " targets}";
    };
  };
in
{
  config = lib.mkIf (cfg.enable && targets != [ ]) {
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
        wantedBy = targets;
        partOf = targets;
        timerConfig = {
          OnActiveSec = "30min";
          OnUnitActiveSec = "30min";
        };
      };
      "site-wallpaper-fetch@" = {
        partOf = targets;
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
