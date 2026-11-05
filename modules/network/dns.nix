{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  collectorConfig = (pkgs.formats.yaml { }).generate "dns-events.yaml" (
    import ../../lib/dns-collector.nix { }
  );
  hardened = import ../../lib/service-hardening.nix // {
    LogRateLimitIntervalSec = 0;
    Restart = "on-failure";
    RestartSec = "2s";
    SupplementaryGroups = [
      "site-network-logs"
      "site-network-policy"
    ];
  };
in
{
  options.site.network.dns.enable = lib.mkEnableOption "domain-aware encrypted DNS";
  config = lib.mkIf cfg.dns.enable {
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNS = lib.optional (!cfg.lockdown.enable) "127.0.0.1:${toString (cfg.dnsPolicy.frontPort or 5300)}";
        FallbackDNS = [ ];
        Domains = [ "~." ];
        DNSOverTLS = false;
        DNSSEC = false;
        LLMNR = false;
        MulticastDNS = false;
        Cache = false;
      };
    };
    networking.resolvconf.enable = false;
    networking.nameservers = lib.mkForce [ ];
    networking.dhcpcd.extraConfig = "nohook resolv.conf";
    # Keep DHCP/RA resolvers out of the policy resolver's routing domains.
    networking.networkmanager.dns = lib.mkIf config.networking.networkmanager.enable (
      lib.mkForce "none"
    );
    users.groups.site-network-logs = { };
    systemd.services = {
      site-dns-events = {
        description = "DNS query and response journal";
        wantedBy = [ "multi-user.target" ];
        before = [ "site-dns.service" ];
        serviceConfig = hardened // {
          ExecStart = "${pkgs.dns-collector}/bin/go-dnscollector -config ${collectorConfig}";
          MemoryDenyWriteExecute = true;
          Group = "site-network-logs";
          RuntimeDirectory = "site-dns-events";
          RuntimeDirectoryMode = "0750";
          UMask = "0007";
        };
      };
      site-dns = {
        description = "DNS classification, per-policy caches and authenticated race branches";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "site-dns-events.service"
        ]
        ++ [ "site-network-policy.service" ];
        requires = [ "site-network-policy.service" ];
        partOf = [ "site-network-policy.service" ];
        wants = [
          "site-dns-events.service"
          "site-dns-race-cn.service"
          "site-dns-race-global.service"
        ];
        serviceConfig = hardened // {
          ExecStart = "${pkgs.dnsdist}/bin/dnsdist --supervised --disable-syslog -C ${cfg.activePolicy}/dnsdist.conf";
        };
      };
    }
    // lib.genAttrs [ "site-dns-race-cn" "site-dns-race-global" ] (
      unit:
      let
        group = lib.removePrefix "site-dns-race-" unit;
      in
      {
        description = "Parallel DNS race for ${group}";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "site-dns-events.service"
        ]
        ++ [ "site-network-policy.service" ];
        requires = [ "site-network-policy.service" ];
        partOf = [ "site-network-policy.service" ];
        serviceConfig = hardened // {
          ExecStart = "${pkgs.dnsproxy}/bin/dnsproxy --config-path ${cfg.activePolicy}/race-${group}.json";
          MemoryDenyWriteExecute = true;
        };
      }
    );
    environment.systemPackages = [
      pkgs.dig
      (pkgs.writeShellScriptBin "network-dns-log" ''
        exec ${
          pkgs.python3.withPackages (p: [ p.dnspython ])
        }/bin/python3 ${../../scripts/network/dns_log.py} "$@"
      '')
    ];
  };
}
