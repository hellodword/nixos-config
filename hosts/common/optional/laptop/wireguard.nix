{ inputs, lib, pkgs, config, ... }:

{
  sops.secrets."wgcf.priv" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/wgcf.priv;
    format = "binary";
  };


  # systemd.services = {
  #   "wg-quick-wgcf" = {
  #     after = lib.mkForce ([ "network.target" ]
  #       ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
  #       ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ]);
  #   };
  # };

  systemd.services = lib.mergeAttrs
    {
      "wg-quick-wgcf" = {
        after = lib.mkForce ([ "network.target" ]
          ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
          ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ]);
      };
    }

    (
      lib.optionalAttrs
        config.services.v2ray.enable
        {
          v2ray.serviceConfig.ExecStartPre = lib.mkAfter [
            "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY -m set --match-set wgcf dst -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY -m set --match-set wgcf dst -j RETURN || true'"
            "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m set --match-set wgcf dst -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set wgcf dst -j RETURN || true'"
          ];
        }
    )
  ;

  systemd.network.wait-online.ignoredInterfaces = [ "wgcf" ];

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
          ip -6 rule del fwmark 41820 lookup main || true

          iptables -t mangle -D OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString table} || true

          iptables -w 3 -t mangle -D V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -D V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

          iptables -w 3 -t nat -D POSTROUTING -m mark --mark ${toString table} -j ${name}_REWRITE || true
          iptables -w 3 -t nat -F ${name}_REWRITE || true
          iptables -w 3 -t nat -X ${name}_REWRITE || true

          ip6tables -w 3 -t nat -D POSTROUTING -m mark --mark 41820 -j ${name}_bypass_REWRITE || true
          ip6tables -w 3 -t nat -F ${name}_bypass_REWRITE || true
          ip6tables -w 3 -t nat -X ${name}_bypass_REWRITE || true
        '';
      };

      upCommon = pkgs.writeShellApplication {
        name = "up";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
        text = ''
          set -x

          ipset create ${name} hash:ip family inet || true
          ipset list ${name} > /dev/null
          ipset create ${name}6 hash:ip family inet6 || true
          ipset list ${name}6 > /dev/null

          ipv4="$(ip -f inet addr show ${name} | awk '/inet / {print $2}')"
          ipv4="$(echo "$ipv4" | grep -oP '\d+\.\d+\.\d+\.\d+')"

          ip -4 rule add fwmark ${toString table} lookup ${toString table}

          iptables -t mangle -I OUTPUT -m set --match-set ${name} dst -j MARK --set-mark ${toString table}

          iptables -w 3 -t mangle -C V2RAY -m set --match-set ${name} dst -j RETURN || iptables -w 3 -t mangle -I V2RAY -m set --match-set ${name} dst -j RETURN || true
          iptables -w 3 -t mangle -C V2RAY_MARK -m set --match-set ${name} dst -j RETURN || iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set ${name} dst -j RETURN || true

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

      upBypassIPv6 = pkgs.writeShellApplication {
        name = "up";
        runtimeInputs = with pkgs; [ ipset iptables iproute2 gawk gnugrep ];
        text = ''
          set -x

          ip6tables -w 3 -t nat -N ${name}_bypass_REWRITE
          ip6tables -w 3 -t nat -I POSTROUTING -m mark --mark 41820 -j ${name}_bypass_REWRITE

          ip -6 rule add fwmark 41820 lookup main

          ipv6_default_interface=""
          for (( i=1; i <= 20; ++i ))
          do
            ipv6_default_interface="$(ip -6 route list | grep '^default' | grep -oP '(?<= dev )[a-z\-\d]+' || true)"
            if [ -n "$ipv6_default_interface" ]; then
              break
            fi
            sleep 3s
          done

          if [ -n "$ipv6_default_interface" ];
          then
            ipv6="$(ip -f inet6 addr show "$ipv6_default_interface" | awk '/inet6 / {print $2}' | head -n 1 | grep -oP '^[a-f\d:]+')"
            ip6tables -t nat -I ${name}_bypass_REWRITE -m mark --mark 41820 -j SNAT --to-source "$ipv6"
          fi
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
        ${downCommon}/bin/down
        ${upCommon}/bin/up
        ${upRouteAllIPv6AndICMPv4}/bin/up
        ${upBypassIPv6}/bin/up
      '';
      preDown = '''';
      preUp = '''';
      privateKeyFile = "${config.sops.secrets."wgcf.priv".path}";
      table = "${toString(table)}";
    };

}
