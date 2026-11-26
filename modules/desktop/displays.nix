{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.desktop;
  sandbox =
    directory:
    import ../../lib/desktop-service-hardening.nix {
      persistRoot = config.site.storage.persistRoot;
      stateDirectory = directory;
    };
in
{
  config = lib.mkIf (cfg.enable && cfg.sway.enable) {
    environment.systemPackages = [
      pkgs.kanshi
      pkgs.wdisplays
    ];
    systemd.user.tmpfiles.rules = [
      "d %h/.config/kanshi 0700 - - -"
      "f %h/.config/kanshi/config 0600 - - -"
    ];
    systemd.user.services.kanshi = {
      description = "Restore saved display combinations";
      wantedBy = [ "site-sway.target" ];
      partOf = [ "site-sway.target" ];
      after = [
        "graphical-session.target"
        "systemd-tmpfiles-setup.service"
      ];
      requires = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = sandbox ".config/kanshi" // {
        # kanshictl discovers the daemon's per-display socket in this directory.
        ReadWritePaths = [ "%t" ];
        ExecStart = "${pkgs.kanshi}/bin/kanshi -c %h/.config/kanshi/config";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
    systemd.user.services.wdisplays = {
      description = "Adjust displays and save their layout";
      partOf = [ "site-sway.target" ];
      after = [ "kanshi.service" ];
      requisite = [ "site-sway.target" ];
      path = [ pkgs.kanshi ];
      serviceConfig = sandbox ".config/kanshi" // {
        ExecStart = "${pkgs.wdisplays}/bin/wdisplays --kanshi --no-auto-apply";
        # Mesa probes mapped memory when creating the Wayland EGL surface.
        SystemCallFilter = [
          "@system-service"
          "mincore"
        ];
        PrivateDevices = false;
        DevicePolicy = "closed";
        DeviceAllow = [ "char-drm rw" ];
        RuntimeDirectory = "wdisplays";
        Environment = [ "XDG_CACHE_HOME=%t/wdisplays" ];
      };
    };
  };
}
