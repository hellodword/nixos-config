{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  journalUnits =
    lib.optionals cfg.dns.enable [
      "site-dns"
      "site-dns-events"
      "site-dns-race-cn"
      "site-dns-race-global"
    ]
    ++ lib.optional cfg.singBox.enable "sing-box";
  journalConfig = pkgs.writeText "journald-network.conf" ''
    [Journal]
    Storage=persistent
    SystemMaxUse=4G
    SystemMaxFileSize=64M
    MaxRetentionSec=7day
    Compress=yes
    RateLimitIntervalSec=0
    LineMax=512K
  '';
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
    environment.etc."systemd/journald@network.conf".source = journalConfig;
    systemd.services =
      lib.genAttrs journalUnits (_: {
        serviceConfig.LogNamespace = "network";
      })
      // {
        "systemd-journald@network" = {
          overrideStrategy = "asDropin";
          # The namespace opens its persistent files at startup. Wait for the
          # impermanence bind mount rather than writing into an ephemeral root.
          unitConfig.RequiresMountsFor = [ "/var/log/journal" ];
          restartTriggers = [ journalConfig ];
          stopIfChanged = false;
        };
        site-network-logrotate = lib.mkIf cfg.lockdown.enable {
          description = "Rotate Mullvad diagnostic logs";
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "logrotate";
            ExecStart = "${pkgs.logrotate}/bin/logrotate --state /var/lib/logrotate/site-network.status ${rotation}";
          };
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
