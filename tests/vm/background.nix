{ scenario }:
{ config, lib, ... }:
let
  backup = config.site.backup.enable or false;
  network =
    (config.site.network.dns.enable or false) || (config.site.network.singBox.enable or false);
  desktop = config.site.desktop.enable or false;
  wallpaper = desktop && (config.site.desktop.sway.enable || config.site.desktop.i3.enable);
  deferred =
    names:
    lib.genAttrs names (_: {
      wantedBy = lib.mkForce [ ];
    });
in
{
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
