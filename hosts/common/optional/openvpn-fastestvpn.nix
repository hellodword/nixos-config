{ config, lib, pkgs, ... }:

let
  # TODO use the parameters (tun name, ip) that openvpn passed to these scripts.
  # https://openvpn.net/community-resources/reference-manual-for-openvpn-2-0/
  # cmd tun_dev tun_mtu link_mtu ifconfig_local_ip ifconfig_remote_ip [ init | restart ]
  down = pkgs.writeShellApplication {
    name = "fastestvpn.down";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 ];
    text = ''
      set -x

      ip -4 rule del fwmark 51822 lookup 51822 || true

      iptables -t mangle -D OUTPUT -m set --match-set fastestvpn dst -j MARK --set-mark 51822 || true

      iptables -w 3 -t mangle -D V2RAY -m set --match-set fastestvpn dst -j RETURN || true
      iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set fastestvpn dst -j RETURN || true

      iptables -w 3 -t nat -D POSTROUTING -m mark --mark 51822 -j FASTESTVPN_REWRITE || true
      iptables -w 3 -t nat -F FASTESTVPN_REWRITE || true
      iptables -w 3 -t nat -X FASTESTVPN_REWRITE || true
    '';
  };

  up = pkgs.writeShellApplication {
    name = "fastestvpn.up";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
    text = ''
      set -x

      ${down}/bin/fastestvpn.down

      ipset create fastestvpn hash:ip || true
      ipset list fastestvpn > /dev/null

      ipv4="$(ip -f inet addr show fastestvpn | awk '/inet / {print $2}')"
      ipv4="$(echo "$ipv4" | grep -oP '\d+\.\d+\.\d+\.\d+')"

      ip -4 route add default dev fastestvpn src "$ipv4" table 51822
      ip -4 rule add fwmark 51822 lookup 51822

      iptables -t mangle -I OUTPUT -m set --match-set fastestvpn dst -j MARK --set-mark 51822

      iptables -w 3 -t mangle -I V2RAY -m set --match-set fastestvpn dst -j RETURN || true
      iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set fastestvpn dst -j RETURN || true

      iptables -w 3 -t nat -N FASTESTVPN_REWRITE
      iptables -w 3 -t nat -I POSTROUTING -m mark --mark 51822 -j FASTESTVPN_REWRITE
      iptables -t nat -I FASTESTVPN_REWRITE -m mark --mark 51822 -j SNAT --to-source "$ipv4"
    '';
  };
in
{
  sops.secrets."fastestvpn.auth" = {
    sopsFile = ../../${config.networking.hostName}/secrets/fastestvpn.auth;
    format = "binary";
  };


  systemd.services."openvpn-fastestvpn" =
    let
      require = [ "network.target" ]
        ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
        ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ];
    in
    {
      requires = lib.mkForce require;
      after = lib.mkForce require;
      # before = [ ]
      #   # (maybe) fix: a stop job is running for dhcp
      #   ++ lib.optionals config.networking.dhcpcd.enable [ "dhcpcd.service" ];
      # preStart = '''';
      # preStop = '''';
    };

  /*
    route-nopull same as Table=off in wg

    specific tun interface name:
      dev-type tun
      dev fastestvpn
  */
  services.openvpn.servers."fastestvpn".config = ''
    script-security 2
    route-nopull
    dev-type tun
    dev fastestvpn
    client
    nobind
    config /usr/local/etc/openvpn/client/fastestvpn.ovpn
    auth-user-pass ${config.sops.secrets."fastestvpn.auth".path}
    up ${up}/bin/fastestvpn.up
    down ${down}/bin/fastestvpn.down
  '';

  /*
    remote ... ...
    proto ...
    cipher ...
    <ca>
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
    </ca>
  */
}
