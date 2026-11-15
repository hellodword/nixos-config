{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  state = "/run/site-network-exclude";
  address = "169.254.53.54";
  policy = pkgs.writeText "network-exclude.json" (
    builtins.toJSON {
      inherit state address;
      upstreams = cfg.exclude.dns;
      bootstrap = cfg.exclude.bootstrap;
      tailnet = config.services.tailscale.enable;
      user = "site-exclude-dns";
      python = "${pkgs.python3}/bin/python3";
      dnsproxy = "${pkgs.dnsproxy}/bin/dnsproxy";
      setpriv = "${pkgs.util-linux}/bin/setpriv";
      mount = "${pkgs.util-linux}/bin/mount";
      sudo = "/run/wrappers/bin/sudo";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      exclude = "${config.services.mullvad-vpn.package}/bin/mullvad-exclude";
    }
  );
  command = "${pkgs.python3}/bin/python3 -Es ${../../scripts/network}/exclude.py ${policy}";
in
{
  options.site.network.exclude = {
    dns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tls://223.5.5.5"
        "https://223.6.6.6/dns-query"
      ];
      description = "Default real-address DNS upstreams for excluded applications and site-direct containers.";
    };
    bootstrap = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tls://223.5.5.5"
        "https://223.6.6.6/dns-query"
      ];
      description = "IP-addressed DNS upstreams used to resolve excluded DNS server hostnames.";
    };
  };
  config = lib.mkIf cfg.lockdown.enable {
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "network-exclude" ''
        exec ${command} "$@"
      '')
    ];
    users.users.site-exclude-dns = {
      isSystemUser = true;
      group = "site-exclude-dns";
    };
    users.groups.site-exclude-dns = { };
    networking.interfaces.lo.ipv4.addresses = [
      {
        inherit address;
        prefixLength = 32;
      }
    ];
    systemd.services.site-network-exclude-dns = {
      description = "Real-address DNS for excluded applications and containers";
      wantedBy = [ "multi-user.target" ];
      after = [
        "mullvad-daemon.service"
        "network-addresses-lo.service"
      ];
      requires = [ "network-addresses-lo.service" ];
      wants = [ "mullvad-daemon.service" ];
      serviceConfig = (import ../../lib/service-hardening.nix) // {
        DynamicUser = false;
        ProtectControlGroups = false;
        RestrictSUIDSGID = false;
        CapabilityBoundingSet = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_SETPCAP"
          "CAP_NET_BIND_SERVICE"
          "CAP_DAC_OVERRIDE"
          "CAP_CHOWN"
          "CAP_KILL"
        ];
        RuntimeDirectory = "site-network-exclude";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = "yes";
        Type = "notify";
        TimeoutStartSec = "15s";
        TimeoutStopSec = "10s";
        ExecStart = "${config.services.mullvad-vpn.package}/bin/mullvad-exclude ${command} --serve";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
    networking.nftables.tables.site_exclude = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority -20; policy accept;
          ip daddr ${address} iifname "lo" ct mark set 0xf41 accept
          ip daddr ${address} iifname "br-site-direct" meta l4proto { tcp, udp } th dport 53 ct mark set 0xf41 accept
          ip daddr ${address} drop
        }
      '';
    };
    networking.firewall.extraInputRules = ''
      ip daddr ${address} iifname "br-site-direct" meta l4proto { tcp, udp } th dport 53 accept
    '';
  };
}
