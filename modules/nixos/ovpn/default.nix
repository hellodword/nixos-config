{ config, lib, pkgs, ... }:

let

  cfg = config.ovpn;
  makeOpenVPN = cfg: name:
    let
      # use the parameters (tun name, ip) that openvpn passed to these scripts.
      # https://openvpn.net/community-resources/reference-manual-for-openvpn-2-0/
      # cmd tun_dev tun_mtu link_mtu ifconfig_local_ip ifconfig_remote_ip [ init | restart ]
      down = pkgs.writeShellApplication {
        name = "down";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 ];
        text = ''
          set -x

          ip -4 rule del fwmark ${toString cfg.table} lookup ${toString cfg.table} || true

          iptables -t mangle -D OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString cfg.table} || true

          iptables -w 3 -t mangle -D V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

          iptables -w 3 -t nat -D POSTROUTING -m mark --mark ${toString cfg.table} -j ${name}_REWRITE || true
          iptables -w 3 -t nat -F ${name}_REWRITE || true
          iptables -w 3 -t nat -X ${name}_REWRITE || true
        '';
      };

      up = pkgs.writeShellApplication {
        name = "up";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
        text = ''
          set -x

          ${down}/bin/down

          ipset create ${name} hash:ip || true
          ipset list ${name} > /dev/null

          ipv4="$(ip -f inet addr show ${name} | awk '/inet / {print $2}')"
          ipv4="$(echo "$ipv4" | grep -oP '\d+\.\d+\.\d+\.\d+')"

          ip -4 route add default dev ${name} src "$ipv4" table ${toString cfg.table}
          ip -4 rule add fwmark ${toString cfg.table} lookup ${toString cfg.table}

          iptables -t mangle -I OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString cfg.table}

          iptables -w 3 -t mangle -I V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

          iptables -w 3 -t nat -N ${name}_REWRITE
          iptables -w 3 -t nat -I POSTROUTING -m mark --mark ${toString cfg.table} -j ${name}_REWRITE
          iptables -t nat -I ${name}_REWRITE -m mark --mark ${toString cfg.table} -j SNAT --to-source "$ipv4"
        '';
      };
    in
    {
      /*
        route-nopull same as Table=off in wg

        specific tun interface name:
          dev-type tun
          dev goose
      */
      config = ''
        route-nopull
        dev-type tun
        dev ${name}
        client
        nobind
        config ${cfg.extraConfig}
        auth-user-pass ${cfg.auth}
        script-security 2
        up ${up}/bin/up
        down ${down}/bin/down
      '';
    };
  setOpenVPN = cfg: name:
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
in
{
  options.ovpn.servers = lib.mkOption {
    default = { };
    type = with lib.types; attrsOf (submodule {
      options = {
        table = lib.mkOption {
          type = lib.types.int;
          description = "";
          default = "";
        };
        auth = lib.mkOption {
          type = lib.types.path;
          description = "";
          default = "";
        };
        extraConfig = lib.mkOption {
          type = lib.types.path;
          description = "";
          default = "";
        };
      };
    });
  };

  config = lib.mkIf (cfg.servers != { }) {

    services.openvpn.servers = (lib.listToAttrs (lib.mapAttrsFlatten (name: value: lib.nameValuePair "${name}" (makeOpenVPN value name)) cfg.servers));

    systemd.services = (lib.listToAttrs (lib.mapAttrsFlatten (name: value: lib.nameValuePair "openvpn-${name}" (setOpenVPN value name)) cfg.servers));

  };
}
