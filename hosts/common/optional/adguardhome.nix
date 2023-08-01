{ lib, inputs, config, pkgs, ... }:


let
  # https://dns.iui.im/
  # udp:53
  # tcp:53
  # tcp:853 / DoT
  directIP = [
    "114.114.114.114"
    "114.114.115.115"
    "114.114.114.119"
    "114.114.115.119"
    "114.114.114.110"
    "114.114.115.110"

    # ali
    "223.5.5.5"
    "223.6.6.6"

    # baidu
    "180.76.76.76"

    # dnspod
    "119.29.29.29"
    "182.254.116.116"
    "119.28.28.28"
    "182.254.118.118"
    "120.53.53.53"
    "1.12.12.12"

    # google
    "8.8.4.4"

    # cloudflare
    "1.0.0.1"

    # quard9
    "9.9.9.10"

    # opendns
    "208.67.222.222"

    # adguardhome
    "94.140.14.14"
  ];

  directIPv6 = [
    # cloudflare
    "2606:4700:4700:0:0:0:0:1001"
    # google
    "2001:4860:4860:0:0:0:0:8844"
    # quard9
    "2620:fe::9"
  ];

  upBypass = pkgs.writeShellApplication {
    name = "up";
    runtimeInputs = with pkgs; [ ipset iptables ];
    text = ''
      set -x

      ipset list adguardhome_bypass > /dev/null || ipset create adguardhome_bypass hash:ip family inet
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass "+ip) directIP)}

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820
    '';
  };

  upBypass6 = pkgs.writeShellApplication {
    name = "up";
    runtimeInputs = with pkgs; [ ipset iptables ];
    text = ''
      set -x

      ipset list adguardhome_bypass6 > /dev/null || ipset create adguardhome_bypass6 hash:ip family inet6
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 "+ip) directIPv6)}

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820
    '';
  };
in
{

  environment.systemPackages = with pkgs; [
    dig
    knot-dns
    curl
    coreutils
    iproute2
  ];

  services.resolved.enable = lib.mkForce false;

  networking.resolvconf = {
    enable = true;
    dnsExtensionMechanism = false;
    dnsSingleRequest = false;
    extraConfig = "";
    extraOptions = [ ];
    # to adguardhome
    useLocalResolver = true;
    package = lib.mkForce pkgs.openresolv;
  };

  systemd.services = {
    "adguardhome" = {
      serviceConfig = {
        # ipset
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        ExecStartPre = [
          # 直连
          "+${upBypass}/bin/up"
          "+${upBypass6}/bin/up"
        ];
      };
    };
  };

  # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/adguardhome.nix
  services.adguardhome = {
    enable = true;
    extraArgs = [ ];
    mutableSettings = true;
    openFirewall = false;
    settings = {
      bind_host = "127.0.0.1";
      bind_port = 33380;
      # fix
      http = {
        address = "127.0.0.1:33380";
      };

      schema_version = pkgs.adguardhome.schema_version;
      users = [
        inputs.nixos-privates.adguardhome.user
      ];
      dns = {
        # fix: cannot unmarshal !!seq into filtering.BlockedServices
        blocked_services = { };

        # v2ray UDP issue https://github.com/v2fly/v2ray-core/issues/68
        bind_hosts = [
          "127.0.0.1"
          "::1"
        ];
        bootstrap_dns = [
          "tls://120.53.53.53"
        ];
        upstream_dns = [
          # cloudflare
          "tls://1.0.0.1"
          # google
          "tls://8.8.4.4"
          # quard9
          "tls://9.9.9.10"
          # opendns
          "tls://208.67.222.222"
          # adguardhome
          "tls://94.140.14.14"
          # cloudflare
          "tls://[2606:4700:4700:0:0:0:0:1001]"
          # google
          "tls://[2001:4860:4860:0:0:0:0:8844]"
          # quard9
          "tls://[2620:fe::9]"
        ];
        upstream_dns_file = "${inputs.you-know-who}/adguard-home/whitelist_full_combine.txt";
        rewrites = [
          { domain = "challenges.cloudflare.com"; answer = "2606:4700::6812:7b9"; }
          { domain = "chat.openai.com"; answer = "2606:4700::6812:7b9"; }
        ];

        ipset = [ ]
          ++ lib.optionals (builtins.hasAttr "wgcf" config.networking.wg-quick.interfaces)
          [
            "${lib.concatStringsSep ","
            [
              "imgur.com"
              "*.imgur.com"
              "imgur.io"
              "*.imgur.io"

              "openai.com"
              "*.openai.com"
              "challenges.cloudflare.com"

            ]}/wgcf,wgcf6"
          ];

      };
    };
  };
}
