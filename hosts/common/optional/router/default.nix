# https://easonyang.com/posts/transparent-proxy-in-router-gateway/
# https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
# https://github.com/AdguardTeam/AdGuardHome/issues/5582#issuecomment-1466946624
{ pkgs, config, ... }:

let
  router-adguardhome-bind-host = pkgs.writeShellApplication {
    name = "router-adguardhome-bind-host";
    runtimeInputs = with pkgs; [ procps iptables iproute2 gawk ];
    text = ''
      iface=$(ip route get 255.255.255.255 | head -n 1 | awk "{print \$4}")
      [ -n "$iface" ]

      sysctl -w "net.ipv4.conf.$iface.route_localnet=1"

      iptables -t nat -C PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.settings.bind_port} -j DNAT --to 127.0.0.1:${builtins.toString config.services.adguardhome.settings.bind_port} || iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.settings.bind_port} -j DNAT --to 127.0.0.1:${builtins.toString config.services.adguardhome.settings.bind_port}

      iptables -t nat -C PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to 127.0.0.1:53 || iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to 127.0.0.1:53
      iptables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to 127.0.0.1:53 || iptables -t nat -A PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to 127.0.0.1:53

      ip6tables -t nat -C PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.settings.bind_port} -j DNAT --to "[::1]:${builtins.toString config.services.adguardhome.settings.bind_port}" || ip6tables -t nat -A PREROUTING -i "$iface" -p tcp --dport ${builtins.toString config.services.adguardhome.settings.bind_port} -j DNAT --to "[::1]:${builtins.toString config.services.adguardhome.settings.bind_port}"

      ip6tables -t nat -C PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to "[::1]:53" || ip6tables -t nat -A PREROUTING -i "$iface" -p tcp --dport 53 -j DNAT --to "[::1]:53"
      ip6tables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to "[::1]:53" || ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to "[::1]:53"
    '';
  };
in
{
  # services.adguardhome.settings.bind_host = lib.mkForce "0.0.0.0";
  systemd.services."adguardhome".serviceConfig.ExecStartPre = [
    "+${router-adguardhome-bind-host}/bin/router-adguardhome-bind-host"
  ];

  # TODO DHCP Server

  # boot.kernel.sysctl = {
  #   "net.ipv4.ip_forward" = "1";
  # };

  # system.activationScripts.iptables-snat.text = ''
  #   iface=$(ip route get 255.255.255.255 | head -n 1 | awk "{print \$4}")
  #   ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -o $iface -j MASQUERADE || ${pkgs.iptables}/bin/iptables -t nat -I POSTROUTING -o $iface -j MASQUERADE
  # '';
}
