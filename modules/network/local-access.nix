{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  firewall = config.networking.firewall;
  private4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16";
  native4 = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "255.255.255.255/32"
  ];
  tailnet = config.services.tailscale;
  ports =
    settings: protocol:
    map toString settings."allowed${protocol}Ports"
    ++ map (r: "${toString r.from}-${toString r.to}") settings."allowed${protocol}PortRanges";
  publicRules =
    destination: verdict:
    lib.concatStrings (
      lib.mapAttrsToList (
        interface: settings:
        lib.concatMapStrings
          (
            protocol:
            let
              values = ports settings protocol;
            in
            lib.optionalString (values != [ ]) ''
              ${
                lib.optionalString (interface != "default") "iifname ${builtins.toJSON interface}"
              } meta l4proto ${lib.toLower protocol} ${destination} { ${lib.concatStringsSep ", " values} } ${verdict}
            ''
          )
          [
            "TCP"
            "UDP"
          ]
      ) firewall.allInterfaces
    );
  # A wildcard UDP server chooses its source during the first route lookup,
  # before OUTPUT can recover the incoming connection's mark.
  udpPorts = lib.unique (
    lib.concatMap (settings: ports settings "UDP") (lib.attrValues firewall.allInterfaces)
  );
  routes = action: ''
    # The local WireGuard peer is an internal DNS endpoint, not a LAN host.
    ip -4 rule ${action} pref 88 to 10.67.0.1 lookup 1836018789 protocol 99
    ip -4 rule ${action} pref 89 to 10.67.0.1 unreachable protocol 99
    ${lib.concatMapStringsSep "\n" (
      prefix: "ip -4 rule ${action} pref 92 to ${prefix} lookup main protocol 99"
    ) native4}
    ${lib.concatMapStringsSep "\n"
      (
        family:
        lib.concatMapStringsSep "\n" (
          port: "ip ${family} rule ${action} pref 96 iif lo ipproto udp sport ${port} lookup main protocol 99"
        ) udpPorts
      )
      [
        "-4"
        "-6"
      ]
    }
  '';
  trusted = verdict: ''
    ip saddr { ${private4} } ${verdict}
    meta nfproto ipv4 iifname @docker_bridges ${verdict}
    ${lib.optionalString tailnet.enable ''
      iifname "${tailnet.interfaceName}" ip saddr 100.64.0.0/10 ${verdict}
      iifname "${tailnet.interfaceName}" ip6 saddr fd7a:115c:a1e0::/48 ${verdict}
    ''}
  '';
in
{
  options.site.network.localAccess.enable =
    lib.mkEnableOption "native IPv4 private networks and trusted development-service access";
  config = lib.mkIf cfg.localAccess.enable {
    networking.nftables = {
      enable = true;
      flushRuleset = false;
      tables.site_local_access = {
        family = "inet";
        content = ''
          # Docker's inventory service maintains only ordinary bridge names.
          set docker_bridges { type ifname; }
          chain admitted {
            ct mark set 0xf41 meta mark set 0x6c6f636c accept
          }
          chain input {
            type filter hook input priority -14; policy accept;
            ${lib.optionalString cfg.lockdown.enable ''iifname "wg0-mullvad" return''}
            meta l4proto { tcp, udp } jump services
          }
          chain services {
            ${trusted "jump admitted"}
            ${publicRules "th dport" "jump admitted"}
          }
          chain published {
            ${trusted "jump admitted"}
            # Public declarations name the host port, before Docker DNAT.
            ${publicRules "ct original proto-dst" "jump admitted"}
            drop
          }
          chain forward {
            type filter hook forward priority -14; policy accept;
            ct direction original ct status dnat oifname @docker_bridges jump published
            ${lib.optionalString cfg.lockdown.enable ''
              ip saddr { ${private4} } ip daddr { ${private4}, 224.0.0.0/4, 255.255.255.255 } ct mark set 0xf41
              ${lib.optionalString tailnet.enable ''iifname "${tailnet.interfaceName}" ip daddr { ${private4} } ct mark set 0xf41''}
            ''}
          }
          ${lib.optionalString cfg.lockdown.enable ''
            chain prerouting {
              type filter hook prerouting priority -135; policy accept;
              ct direction reply ct mark 0xf41 meta mark set 0x6d6f6c65
            }
            chain output {
              type route hook output priority -90; policy accept;
              ip daddr 10.67.0.1 return
              ip daddr { ${private4}, 224.0.0.0/4, 255.255.255.255 } ct mark set 0xf41 meta mark set 0x6d6f6c65
              ct direction reply ct mark 0xf41 meta mark set 0x6d6f6c65
            }
          ''}
        '';
      };
    };
    networking.firewall.extraInputRules = ''
      meta mark 0x6c6f636c ct mark 0xf41 accept
    '';
    systemd.services.site-local-routes = lib.mkIf cfg.lockdown.enable {
      description = "Native IPv4 private-network and service reply routes";
      wantedBy = [ "multi-user.target" ];
      before = [ "site-network-routing.service" ];
      after = [ "nftables.service" ];
      requires = [ "nftables.service" ];
      partOf = [ "nftables.service" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = routes "add";
      preStop = routes "del";
    };
  };
}
