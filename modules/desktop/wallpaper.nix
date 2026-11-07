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
      ExecCondition = "${pkgs.systemd}/bin/systemctl --user is-active --quiet ${lib.concatStringsSep " " targets}";
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
    };
  };
in
{
  config = lib.mkIf (cfg.enable && targets != [ ]) {
    systemd.user.tmpfiles.rules = [ "d %h/Pictures/wallpaper 0700 - - -" ];
    systemd.user.services = {
      site-wallpaper = service "rotate";
      site-wallpaper-apply = service "apply";
      site-wallpaper-fetch = lib.recursiveUpdate (service "fetch") {
        serviceConfig.ExecStartPost = "${pkgs.systemd}/bin/systemctl --user --no-block start site-wallpaper-apply.service";
      };
    };
    systemd.user.timers = {
      site-wallpaper = {
        wantedBy = targets;
        partOf = targets;
        timerConfig = {
          OnActiveSec = "1s";
          OnUnitActiveSec = "30min";
        };
      };
      site-wallpaper-fetch = {
        wantedBy = targets;
        partOf = targets;
        timerConfig = {
          OnActiveSec = "10s";
          OnUnitActiveSec = "1h";
        };
      };
    };
  };
}
