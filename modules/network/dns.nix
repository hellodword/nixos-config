{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  resolver4 = cfg.dns.ingressIPv4;
  resolver6 = cfg.dns.ingressIPv6;
  tailnet = config.services.tailscale.enable;
  tailInterface = config.services.tailscale.interfaceName;
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
  options.site.network.dns = {
    enable = lib.mkEnableOption "domain-aware encrypted DNS";
    ingressIPv4 = lib.mkOption {
      type = lib.types.str;
      default = "169.254.53.53";
      internal = true;
      readOnly = true;
    };
    ingressIPv6 = lib.mkOption {
      type = lib.types.str;
      default = "fd53:53:53::53";
      internal = true;
      readOnly = true;
    };
  };
  config = lib.mkIf cfg.dns.enable {
    networking.interfaces.lo.ipv4.addresses = [
      {
        address = resolver4;
        prefixLength = 32;
      }
    ];
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
        DNSStubListenerExtra = [
          resolver4
          resolver6
        ];
      };
    };
    networking.resolvconf.enable = false;
    networking.nameservers = lib.mkForce [ ];
    networking.dhcpcd.extraConfig = "nohook resolv.conf";
    # Keep DHCP/RA resolvers out of the policy resolver's routing domains.
    networking.networkmanager.dns = lib.mkIf config.networking.networkmanager.enable (
      lib.mkForce "none"
    );
    networking.nftables.tables.site_dns = {
      family = "inet";
      content = ''
        set docker_bridges { type ifname; }
        chain dns_dnat {
          ip daddr { 127.0.0.0/8, ${resolver4}${lib.optionalString tailnet ", 100.100.100.100"}${lib.optionalString cfg.lockdown.enable ", 10.67.0.1"} } return
          ip6 daddr { ::1, ${resolver6}${lib.optionalString tailnet ", fd7a:115c:a1e0::53"}${lib.optionalString cfg.lockdown.enable ", fd66:105::1"} } return
          meta nfproto ipv4 ct mark set 0xf41 meta mark set 0x6d6f6c65 dnat ip to ${resolver4}
          meta nfproto ipv6 ct mark set 0xf41 meta mark set 0x6d6f6c65 dnat ip6 to ${resolver6}
        }
        chain output {
          type nat hook output priority -105; policy accept;
          meta l4proto { tcp, udp } th dport 53 jump dns_dnat
        }
        chain prerouting {
          type nat hook prerouting priority -105; policy accept;
          iifname @docker_bridges meta l4proto { tcp, udp } th dport 53 jump dns_dnat
          ${lib.optionalString tailnet ''iifname "${tailInterface}" meta l4proto { tcp, udp } th dport 53 jump dns_dnat''}
        }
        chain clients {
          iifname "lo" ct mark set 0xf41 accept
          iifname @docker_bridges ct mark set 0xf41 accept
          ${lib.optionalString tailnet ''iifname "${tailInterface}" ct mark set 0xf41 accept''}
          drop
        }
        chain input {
          type filter hook input priority -20; policy accept;
          ip daddr ${resolver4} meta l4proto { tcp, udp } th dport 53 jump clients
          ip6 daddr ${resolver6} meta l4proto { tcp, udp } th dport 53 jump clients
          ip daddr ${resolver4} drop
          ip6 daddr ${resolver6} drop
        }
        chain replies {
          oifname "lo" accept
          oifname @docker_bridges accept
          ${lib.optionalString tailnet ''oifname "${tailInterface}" accept''}
          drop
        }
        chain postrouting {
          type filter hook postrouting priority 190; policy accept;
          ip saddr ${resolver4} jump replies
          ip6 saddr ${resolver6} jump replies
        }
      '';
    };
    networking.firewall.extraInputRules = ''
      ip daddr ${resolver4} meta l4proto { tcp, udp } th dport 53 ct mark 0xf41 accept
      ip6 daddr ${resolver6} meta l4proto { tcp, udp } th dport 53 ct mark 0xf41 accept
    '';
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
