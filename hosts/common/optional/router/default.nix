# https://easonyang.com/posts/transparent-proxy-in-router-gateway/
# https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
# https://github.com/AdguardTeam/AdGuardHome/issues/5582#issuecomment-1466946624
{
  pkgs,
  config,
  lib,
  ...
}:

let
  router-adguardhome-bind-interface = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [
      procps
      iptables
      iproute2
      gawk
    ];
    text = ''
      iface="$1"
      [ -n "$iface" ]

      sysctl -w "net.ipv4.conf.$iface.route_localnet=1" || true

      iptables -t nat -C PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.port} -j DNAT --to 127.0.0.1:${builtins.toString config.services.adguardhome.port} || iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.port} -j DNAT --to 127.0.0.1:${builtins.toString config.services.adguardhome.port} || true

      iptables -t nat -C PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to 127.0.0.1:53 || iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to 127.0.0.1:53 || true
      iptables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to 127.0.0.1:53 || iptables -t nat -A PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to 127.0.0.1:53 || true

      # ip6tables -t nat -C PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.port} -j DNAT --to "[::1]:${builtins.toString config.services.adguardhome.port}" || ip6tables -t nat -A PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.port} -j DNAT --to "[::1]:${builtins.toString config.services.adguardhome.port}" || true

      # ip6tables -t nat -C PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to "[::1]:53" || ip6tables -t nat -A PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to "[::1]:53" || true
      # ip6tables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to "[::1]:53" || ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to "[::1]:53" || true
    '';
  };
  router-adguardhome-bind-default = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [
      procps
      iproute2
      gawk
    ];
    text = ''
      # 192.168.0.1 been excluded by sing-tun
      iface=$(ip route get 192.168.0.1 | head -n 1 | awk "{print \$4}" || true)
      [ -n "$iface" ]

      ${router-adguardhome-bind-interface}/bin/exe "$iface"
    '';
  };
in
{
  # services.adguardhome.settings.bind_host = lib.mkForce "0.0.0.0";
  # execute before sing-box tun, or the default route will be sb-tun
  systemd.services."sing-box".serviceConfig.ExecStartPre = [
    "+${router-adguardhome-bind-default}/bin/exe"
  ];

  systemd.services."tailscaled".serviceConfig.ExecStartPost = [
    "+${router-adguardhome-bind-interface}/bin/exe ${config.services.tailscale.interfaceName}"
  ];

  # TODO DHCP Server

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = "1";
    "net.ipv6.conf.all.forwarding" = "1";
  };

  # system.activationScripts.iptables-snat.text = ''
  #   iface=$(ip route get 255.255.255.255 | head -n 1 | awk "{print \$4}")
  #   ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -o $iface -j MASQUERADE || ${pkgs.iptables}/bin/iptables -t nat -I POSTROUTING -o $iface -j MASQUERADE
  # '';

  services.tailscale.useRoutingFeatures = lib.mkForce "both";
  services.tailscale.extraUpFlags = lib.mkForce [
    "--advertise-exit-node"
    "--advertise-routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    "--accept-routes=true"
    "--stateful-filtering=false"
  ];
}
