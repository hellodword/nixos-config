{ inputs, lib, pkgs, config, ... }:

{
  sops.secrets."wgcf.priv" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/wgcf.priv;
    format = "binary";
  };

  systemd.services."wg-quick-wgcf".after = lib.mkForce ([ "network.target" ]
    ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
    ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ]);

  networking.wg-quick.interfaces."wgcf" =
    let
      name = "wgcf";
      table = 51820;
      downCommon = pkgs.writeShellApplication {
        name = "down";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 ];
        text = ''
          set -x

          ip -4 rule flush table ${toString table} || true
          ip -6 rule flush table ${toString table} || true

          iptables -t mangle -D OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString table} || true

          iptables -w 3 -t mangle -D V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

          iptables -w 3 -t nat -D POSTROUTING -m mark --mark ${toString table} -j ${name}_REWRITE || true
          iptables -w 3 -t nat -F ${name}_REWRITE || true
          iptables -w 3 -t nat -X ${name}_REWRITE || true
        '';
      };

      upCommon = pkgs.writeShellApplication {
        name = "up";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
        text = ''
          set -x

          ${downCommon}/bin/down

          ipset create ${name} hash:ip || true
          ipset list ${name} > /dev/null

          ipv4="$(ip -f inet addr show ${name} | awk '/inet / {print $2}')"
          ipv4="$(echo "$ipv4" | grep -oP '\d+\.\d+\.\d+\.\d+')"

          iptables -t mangle -I OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString table}

          iptables -w 3 -t mangle -I V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

          iptables -w 3 -t nat -N ${name}_REWRITE
          iptables -w 3 -t nat -I POSTROUTING -m mark --mark ${toString table} -j ${name}_REWRITE
          iptables -t nat -I ${name}_REWRITE -m mark --mark ${toString table} -j SNAT --to-source "$ipv4"
        '';
      };

      upRouteAllIPv6AndICMPv4 = pkgs.writeShellApplication {
        name = "up";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
        text = ''
          set -x

          ip -6 rule add not fwmark ${toString table} table ${toString table}
          ip -4 rule add ipproto icmp lookup ${toString table}
        '';
      };
    in
    {
      address = inputs.nixos-privates.wgcf."laptop".address;
      autostart = true;
      dns = inputs.nixos-privates.wgcf."laptop".dns;
      listenPort = null;
      mtu = 1280;
      peers = [
        {
          allowedIPs = [
            "0.0.0.0/0"
            "::/0"
          ];
          endpoint = inputs.nixos-privates.wgcf."laptop".endpoint;
          persistentKeepalive = 25;
          publicKey = inputs.nixos-privates.wgcf."laptop".publicKey;
        }
      ];
      postDown = ''
        ${downCommon}/bin/down
      '';
      postUp = ''
        ${upCommon}/bin/up
        ${upRouteAllIPv6AndICMPv4}/bin/up
      '';
      preDown = '''';
      preUp = '''';
      privateKeyFile = "${config.sops.secrets."wgcf.priv".path}";
      table = "${toString(table)}";
    };
}
