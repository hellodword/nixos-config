{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tailscale;
  interface = cfg.interfaceName;
  lockdown = import ../../lib/lockdown.nix;
  wrappedTailscale = pkgs.symlinkJoin {
    name = "${pkgs.tailscale.name}-excluded";
    inherit (pkgs.tailscale) pname version meta;
    paths = [ pkgs.tailscale ];
    postBuild = ''
      ln -sf "${pkgs.tailscale}/bin/tailscale" "$out/bin/tailscale"
      rm "$out/bin/tailscaled"
      printf '%s\n' \
        '#!${pkgs.runtimeShell}' \
        'if [[ "$(basename "$0")" != "tailscaled" ]]; then' \
        '  exec "${pkgs.tailscale}/bin/$(basename "$0")" "$@"' \
        'fi' \
        'for arg in "$@"; do' \
        '  if [[ "$arg" == "--cleanup" ]]; then' \
        '    exec ${pkgs.tailscale}/bin/tailscaled "$@"' \
        '  fi' \
        'done' \
        'exec ${config.services.mullvad-vpn.package}/bin/mullvad-exclude ${pkgs.python3}/bin/python3 ${../../scripts/network}/run_excluded.py ${pkgs.tailscale}/bin/tailscaled "$@"' \
        > "$out/bin/tailscaled"
      chmod +x "$out/bin/tailscaled"
      "$out/bin/tailscale" up --help >/dev/null
      rm "$out/lib/systemd/system/tailscaled.service"
      substitute \
        "${pkgs.tailscale}/lib/systemd/system/tailscaled.service" \
        "$out/lib/systemd/system/tailscaled.service" \
        --replace-fail "${pkgs.tailscale}" "$out"
    '';
  };
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
  imports = [ ../core/reserved-ports.nix ];
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        site.reservedPorts = lib.optional (cfg.port > 0) cfg.port;
        systemd.services.tailscaled.restartTriggers = [ config.security.pki.caBundle ];
      }
      (lib.mkIf config.site.network.lockdown.enable {
        services.tailscale.openFirewall = true;
        services.tailscale.package = wrappedTailscale;
        networking.nftables.tables.site-tailnet = {
          family = "inet";
          content = ''
            # Tailnet transport and access to this host stay outside Lockdown.
            # Forwarded Internet connections retain ordinary tunnel protection.
            chain output {
              type route hook output priority -140; policy accept;
              # Both daemons use mangle priority (-150). Tailscale saves part of
              # the packet mark into conntrack; Mullvad expects its exact ct mark.
              meta mark ${lockdown.mark} ct mark set ${lockdown.ctMark}
              oifname "${interface}" ip daddr 100.64.0.0/10 ct mark set ${lockdown.ctMark} meta mark set ${lockdown.mark}
              oifname "${interface}" ip6 daddr fd7a:115c:a1e0::/48 ct mark set ${lockdown.ctMark} meta mark set ${lockdown.mark}
            }
            chain prerouting {
              type filter hook prerouting priority -160; policy accept;
              iifname != "${interface}" fib daddr type local udp dport ${toString cfg.port} ct mark set ${lockdown.ctMark} meta mark set ${lockdown.mark}
            }
            chain input {
              type filter hook input priority -10; policy accept;
              # Classify after routing so exit-node traffic never gains this mark.
              iifname "${interface}" ip saddr 100.64.0.0/10 ct mark set ${lockdown.ctMark}
              iifname "${interface}" ip6 saddr fd7a:115c:a1e0::/48 ct mark set ${lockdown.ctMark}
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
          };
        };
      })
    ]
  );
}
