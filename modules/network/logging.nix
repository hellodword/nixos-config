{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  rotation = pkgs.writeText "mullvad-logrotate.conf" ''
    /var/log/mullvad-vpn/*.log {
      daily
      maxsize 16M
      rotate 4
      maxage 7
      compress
      copytruncate
      missingok
      notifempty
      su root root
    }
  '';
in
{
  config = lib.mkIf (cfg.dns.enable || cfg.singBox.enable || cfg.lockdown.enable) {
    services.journald.settings.Journal = {
      LineMax = "512K";
    };
    systemd.services.site-network-logrotate = lib.mkIf cfg.lockdown.enable {
      description = "Rotate Mullvad diagnostic logs";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "logrotate";
        ExecStart = "${pkgs.logrotate}/bin/logrotate --state /var/lib/logrotate/site-network.status ${rotation}";
      };
    };
    systemd.timers.site-network-logrotate = lib.mkIf cfg.lockdown.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5";
        AccuracySec = "30s";
        Persistent = true;
      };
    };
  };
}
