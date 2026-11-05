{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.desktop;
  layout = import ../../nix/display-layout.nix { inherit pkgs; };
  sandbox =
    directory:
    import ../../lib/desktop-service-hardening.nix {
      persistRoot = config.site.storage.persistRoot;
      stateDirectory = directory;
    };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      lib.optionals cfg.sway.enable [
        pkgs.kanshi
        pkgs.wdisplays
      ]
      ++ lib.optionals cfg.i3.enable [
        pkgs.autorandr
        pkgs.arandr
      ];
    systemd.user.tmpfiles.rules = lib.optionals cfg.sway.enable [
      "d %h/.config/kanshi 0700 - - -"
      "f %h/.config/kanshi/config 0600 - - -"
    ];
    systemd.user.services.kanshi = lib.mkIf cfg.sway.enable {
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
    systemd.user.services.wdisplays = lib.mkIf cfg.sway.enable {
      description = "Adjust displays and save their layout";
      partOf = [ "site-sway.target" ];
      after = [ "kanshi.service" ];
      requisite = [ "site-sway.target" ];
      path = [ pkgs.kanshi ];
      serviceConfig = sandbox ".config/kanshi" // {
        ExecStart = "${pkgs.wdisplays}/bin/wdisplays --kanshi --no-auto-apply";
        PrivateDevices = false;
        DevicePolicy = "closed";
        DeviceAllow = [ "char-drm rw" ];
        RuntimeDirectory = "wdisplays";
        Environment = [ "XDG_CACHE_HOME=%t/wdisplays" ];
      };
    };
    systemd.user.services.autorandr = lib.mkIf cfg.i3.enable {
      description = "Restore saved display profiles; arrange unknown displays automatically";
      wantedBy = [ "site-i3.target" ];
      partOf = [ "site-i3.target" ];
      after = [
        "graphical-session.target"
      ];
      unitConfig.ConditionEnvironment = "XDG_CURRENT_DESKTOP=i3";
      serviceConfig = sandbox ".config/autorandr" // {
        Type = "exec";
        ExecStart = "${layout}/bin/site-display-layout --watch";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
