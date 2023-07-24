{ config, lib, pkgs, ... }:

let

  cfg = config.wg;
  mkWG = cfg: name:
    /*
      # https://blog.imlk.top/posts/policy-routing-with-wg-tunnel/

      [Interface]
      DNS = 1.1.1.1
      MTU = 1280
      Table = off

      PostUp = ip -6 route add ::/0 dev %i table 51820
      PostUp = ip -6 rule add not fwmark 51820 table 51820
      PostUp = ip -6 rule add table main suppress_prefixlength 0

      PostDown = ip -6 rule delete table 51820
      PostDown = ip -6 rule delete table main suppress_prefixlength 0

      PostUp = ipset create %i hash:ip || true; ipset list %i > /dev/null 

      PostUp = ip -4 route add default dev %i src 172.16.0.2 table 51820
      PostUp = ip -4 rule add fwmark 51820 lookup 51820
      PostUp = ip -4 rule add ipproto icmp lookup 51820
      PostDown = ip -4 rule del fwmark 51820 lookup 51820 || true
      PostDown = ip -4 rule del ipproto icmp lookup 51820 || true

      PostUp = iptables -t mangle -C OUTPUT -m set --match-set %i dst -j MARK --set-mark 51820 2>/dev/null || iptables -t mangle -I OUTPUT -m set --match-set %i dst -j MARK --set-mark 51820
      PostUp = iptables -t nat -C POSTROUTING -m mark --mark 51820 -j SNAT --to-source 172.16.0.2 2>/dev/null || iptables -t nat -I POSTROUTING -m mark --mark 51820 -j SNAT --to-source 172.16.0.2
      PostDown = iptables -t mangle -D OUTPUT -m set --match-set %i dst -j MARK --set-mark 51820
      PostDown = iptables -t nat -D POSTROUTING -m mark --mark 51820 -j SNAT --to-source 172.16.0.2

      PostUp = iptables -w 3 -t mangle -C V2RAY -m set --match-set %i dst -j RETURN || iptables -w 3 -t mangle -I V2RAY -m set --match-set %i dst -j RETURN || true
      PostUp = iptables -w 3 -t mangle -C V2RAY_MARK -m set --match-set %i dst -j RETURN || iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set %i dst -j RETURN || true
      PostDown = iptables -w 3 -t mangle -D V2RAY -m set --match-set %i dst -j RETURN || true
      PostDown = iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set %i dst -j RETURN || true

      [Peer]
      AllowedIPs = 0.0.0.0/0
      AllowedIPs = ::/0
    */
    {
      configFile = cfg.config;
    };
  setService = cfg: name:
    let
      require = [ "network.target" ]
        ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
        ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ];
    in
    {
      requires = lib.mkForce require;
      after = lib.mkForce require;
      path = with pkgs; [ ipset iptables iproute2 ];
      # before = [ ]
      #   # (maybe) fix: a stop job is running for dhcp
      #   ++ lib.optionals config.networking.dhcpcd.enable [ "dhcpcd.service" ];
      # preStart = '''';
      # sometimes buggy when /tmp/<name>.conf was removed https://github.com/NixOS/nixpkgs/blob/86388ba6881aae014fb945ede340083fef0fd637/nixos/modules/services/networking/wg-quick.nix#L263-L265
      preStop = lib.mkForce ''
        cp ${cfg.config} /tmp/${name}.conf

        wg-quick down /tmp/${name}.conf
      '';
    };
in
{
  options.wg.servers = lib.mkOption {
    default = { };
    type = with lib.types; attrsOf (submodule {
      options = {
        config = lib.mkOption {
          type = lib.types.path;
          description = "";
          default = "";
        };
      };
    });
  };

  config = lib.mkIf (cfg.servers != { }) {

    networking.wg-quick.interfaces = (lib.listToAttrs (lib.mapAttrsFlatten (name: value: lib.nameValuePair "${name}" (mkWG value name)) cfg.servers));

    systemd.services = (lib.listToAttrs (
      (lib.mapAttrsFlatten (name: value: lib.nameValuePair "wg-quick-${name}" (setService value name)) cfg.servers) ++
      lib.optionals config.services.v2ray.enable [
        (lib.nameValuePair "v2ray" {
          serviceConfig.ExecStartPre = lib.mkAfter (lib.flatten (lib.mapAttrsFlatten
            (name: value: [
              "+${pkgs.bash}/bin/bash -c 'iptables -w 3 -t mangle -I V2RAY -m set --match-set ${name} dst -j RETURN || true'"
              "+${pkgs.bash}/bin/bash -c 'iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true'"
            ])
            cfg.servers));
        })
      ]
    ));
  };
}
