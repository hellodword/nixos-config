{ scenario }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  backup = config.site.backup.enable or false;
  network =
    (config.site.network.dns.enable or false) || (config.site.network.singBox.enable or false);
  desktop = config.site.desktop.enable or false;
  wallpaper = desktop && config.site.desktop.sway.enable;
  deferred =
    names:
    lib.genAttrs names (_: {
      wantedBy = lib.mkForce [ ];
    });
in
{
  environment.sessionVariables = lib.mkIf desktop {
    QT_LOGGING_RULES = "qt.quick.focus=true";
  };
  services.displayManager.sddm.settings.General.GreeterEnvironment =
    lib.mkIf desktop "QT_LOGGING_RULES=qt.quick.focus=true";
  environment.systemPackages = lib.optionals desktop [
    (pkgs.writeShellScriptBin "vm-idle-inhibit" ''
      exec ${
        pkgs.python3.withPackages (p: [
          p.dbus-python
          p.pygobject3
        ])
      }/bin/python3 ${../fixtures/idle_inhibit.py}
    '')
  ];
  # The VPS scenario supplies the authenticated time source.
  systemd.services = deferred (
    lib.optional (scenario != "vps" && config.services.chrony.enable) "chronyd"
  );

  # Scheduled operations start after their scenario has prepared its data and
  # peers. Notification retries and status refreshes keep their normal schedule.
  systemd.timers = deferred (
    lib.optionals (scenario == "backup" && backup) (
      map (name: "site-backup-${name}-automatic") (
        builtins.attrNames (lib.filterAttrs (_: target: target.automatic.enable) config.site.backup.targets)
      )
    )
    ++ lib.optional (scenario == "network" && network) "site-network-rules-schedule"
    ++ lib.optional (
      scenario == "network" && (config.site.network.lockdown.enable or false)
    ) "site-network-logrotate"
    ++ lib.optional (
      scenario == "vps" && config.systemd.services ? site-vps-certificate
    ) "site-vps-certificate"
    ++ lib.optional (scenario == "vps" && config.systemd.services ? site-vps-gc) "site-vps-gc"
    ++ lib.optional (config.nix.gc.automatic or false) "nix-gc"
    ++ lib.optional (config.virtualisation.docker.autoPrune.enable or false) "docker-prune"
    ++ lib.optional (
      config.systemd.services ? site-devcontainer-cache-prune
    ) "site-devcontainer-cache-prune"
  );

  # Application workflows use the local background. The desktop scenario owns
  # periodic notifications, wallpaper scheduling and session-exit coverage.
  systemd.user.timers = deferred (
    lib.optional (scenario == "applications" && desktop) "desktop-health"
    ++ lib.optional (scenario == "applications" && wallpaper) "site-wallpaper"
  );
  systemd.user.services.site-wallpaper-schedule = lib.mkIf (scenario == "applications" && wallpaper) {
    unitConfig.ConditionPathExists = "%t/vm-background/wallpaper-schedule";
  };
}
