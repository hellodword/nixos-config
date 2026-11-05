{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tailscale;
  interface = cfg.interfaceName;
  rules =
    action:
    lib.concatMapStringsSep "\n"
      (pair: ''
        ip ${pair.family} rule ${action} pref 80 fwmark 0x80000/0xff0000 lookup main protocol 99
        ip ${pair.family} rule ${action} pref 81 fwmark 0x80000/0xff0000 unreachable protocol 99
        ip ${pair.family} rule ${action} pref 90 to ${pair.prefix} lookup 52 protocol 99
        ip ${pair.family} rule ${action} pref 91 to ${pair.prefix} unreachable protocol 99
      '')
      [
        {
          family = "-4";
          prefix = "100.64.0.0/10";
        }
        {
          family = "-6";
          prefix = "fd7a:115c:a1e0::/48";
        }
      ];
in
{
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      { systemd.services.tailscaled.restartTriggers = [ config.security.pki.caBundle ]; }
      (lib.mkIf config.site.network.lockdown.enable {
        services.tailscale.openFirewall = true;
        networking.nftables.tables.site-tailnet = {
          family = "inet";
          content = ''
            # Tailnet transport and access to this host stay outside Lockdown.
            # Forwarded Internet connections retain ordinary tunnel protection.
            chain output {
              type route hook output priority -140; policy accept;
              # Both daemons use mangle priority (-150). Tailscale saves part of
              # the packet mark into conntrack; Mullvad expects its exact ct mark.
              meta mark 0x6d6f6c65 ct mark set 0xf41
              oifname "${interface}" ip daddr 100.64.0.0/10 ct mark set 0xf41 meta mark set 0x6d6f6c65
              oifname "${interface}" ip6 daddr fd7a:115c:a1e0::/48 ct mark set 0xf41 meta mark set 0x6d6f6c65
            }
            chain prerouting {
              type filter hook prerouting priority -160; policy accept;
              iifname != "${interface}" fib daddr type local udp dport ${toString cfg.port} ct mark set 0xf41 meta mark set 0x6d6f6c65
            }
            chain input {
              type filter hook input priority -10; policy accept;
              # Classify after routing so exit-node traffic never gains this mark.
              iifname "${interface}" ip saddr 100.64.0.0/10 ct mark set 0xf41
              iifname "${interface}" ip6 saddr fd7a:115c:a1e0::/48 ct mark set 0xf41
            }
          '';
        };
        systemd.services.site-tailscale-routes = {
          description = "Route Tailnet addresses before transparent Internet capture";
          before = [ "tailscaled.service" ];
          after = [ "nftables.service" ];
          requires = [ "nftables.service" ];
          partOf = [ "tailscaled.service" ];
          path = [ pkgs.iproute2 ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # Tailscale marks its underlay sockets before their first route lookup.
          # Select the physical source address there, before Mullvad's later SNAT.
          script = rules "add";
          preStop = rules "del";
        };
        systemd.services.tailscaled = {
          requires = [ "site-tailscale-routes.service" ];
          after = [
            "site-tailscale-routes.service"
            "mullvad-daemon.service"
          ];
          startLimitIntervalSec = 0;
          serviceConfig = {
            ProtectControlGroups = false;
            RestartSec = "3s";
            ExecStart = lib.mkForce [
              ""
              (
                "${config.services.mullvad-vpn.package}/bin/mullvad-exclude ${pkgs.python3}/bin/python3 ${../../scripts/network/run_excluded.py} ${cfg.package}/bin/tailscaled"
                + " --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=\${PORT} $FLAGS"
              )
            ];
          };
        };
      })
    ]
  );
}
