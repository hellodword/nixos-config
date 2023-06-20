{ config, lib, pkgs, persistPath, ... }:

let
  # TODO use the parameters (tun name, ip) that openvpn passed to these scripts.
  # https://openvpn.net/community-resources/reference-manual-for-openvpn-2-0/
  # cmd tun_dev tun_mtu link_mtu ifconfig_local_ip ifconfig_remote_ip [ init | restart ]
  down = pkgs.writeShellApplication {
    name = "goose.down";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 ];
    text = ''
      set -x

      ip -4 rule del fwmark 51821 lookup 51821 || true

      iptables -t mangle -D OUTPUT -m set --match-set goose dst -j MARK --set-mark 51821 || true

      iptables -w 3 -t mangle -D V2RAY -m set --match-set goose dst -j RETURN || true
      iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set goose dst -j RETURN || true

      iptables -w 3 -t nat -D POSTROUTING -m mark --mark 51821 -j GOOSE_REWRITE || true
      iptables -w 3 -t nat -F GOOSE_REWRITE || true
      iptables -w 3 -t nat -X GOOSE_REWRITE || true
    '';
  };

  up = pkgs.writeShellApplication {
    name = "goose.up";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk ];
    text = ''
      set -x

      ${down}/bin/goose.down

      ipset create goose hash:ip || true
      ipset list goose > /dev/null

      ipv4="$(ip -f inet addr show goose | awk '/inet / {print $2}')"

      ip -4 route add default dev goose src "$ipv4" table 51821
      ip -4 rule add fwmark 51821 lookup 51821

      iptables -t mangle -I OUTPUT -m set --match-set goose dst -j MARK --set-mark 51821

      iptables -w 3 -t mangle -I V2RAY -m set --match-set goose dst -j RETURN || true
      iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set goose dst -j RETURN || true

      iptables -w 3 -t nat -N GOOSE_REWRITE
      iptables -w 3 -t nat -I POSTROUTING -m mark --mark 51821 -j GOOSE_REWRITE
      iptables -t nat -I GOOSE_REWRITE -m mark --mark 51821 -j SNAT --to-source "$ipv4"
    '';
  };
in
{
  sops.secrets."goose.auth" = {
    sopsFile = ../../${config.networking.hostName}/secrets/goose.auth;
    format = "binary";
  };


  systemd.services."openvpn-goose" =
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
      dev goose
  */
  services.openvpn.servers."goose".config = ''
    script-security 2
    route-nopull
    dev-type tun
    dev goose
    client
    comp-lzo
    nobind
    verb 3
    tun-mtu 9000
    keepalive 5 60
    config /usr/local/etc/openvpn/client/goose.ovpn
    auth-user-pass ${config.sops.secrets."goose.auth".path}
    up ${up}/bin/goose.up
    down ${down}/bin/goose.down
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
  environment.persistence = {
    "${persistPath}".directories = [
      "/usr/local/etc/openvpn/client"
    ];
  };
}
