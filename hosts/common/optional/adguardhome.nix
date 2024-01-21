{ lib, inputs, config, pkgs, ... }:


let
  # udp:53
  # tcp:53
  # tcp:853 / DoT
  # udp:443 / DoH3

  # ECS (Y=支持，N=不支持，P=部分服务器支持)
  # - Google      Y
  # - Cloudflare  N
  # - Quard9      P   https://www.quad9.net/support/faq/#edns

  # 策略
  # bootstrap 直连国内 DoT
  # 直连海外的选择不支持 ECS 的
  #   https://community.cloudflare.com/t/1-1-1-1-supports-ecs/17424/1
  # 其余全是代理请求海外

  ChinaDoT = [
    # "114.114.114.114"
    # "114.114.115.115"
    # "114.114.114.119"
    # "114.114.115.119"
    # "114.114.114.110"
    # "114.114.115.110"

    # ali
    "223.5.5.5"
    "223.6.6.6"

    # # baidu
    # "180.76.76.76"

    # dnspod
    # "119.29.29.29"
    # "182.254.116.116"
    # "119.28.28.28"
    # "182.254.118.118"
    "120.53.53.53"
    "1.12.12.12"
  ];

  ChinaDoT6 = [
    # # ali
    # "2400:3200::1"
    # "2400:3200:baba::1"
  ];

  DoT = [
    # # cloudflare
    # # timeout 3s openssl s_client -connect 1.0.0.1:443 2>/dev/null | openssl x509 -noout -text | grep -P 'DNS:|IP Address:'
    # # x509: certificate is valid for 1.0.0.1, 1.1.1.1, 162.159.36.1, 162.159.46.1, 2606:4700:4700::1001, 2606:4700:4700::1111, 2606:4700:4700::64, 2606:4700:4700::6400
    # "1.0.0.1"
    # # "1.1.1.1"
    # "162.159.36.1"
    # "162.159.46.1"
  ];

  DoTProxy = [
    "1.1.1.1"

    # # google
    # "8.8.4.4"

    # # # quard9
    # # "9.9.9.10"

    # # # opendns
    # # # "208.67.222.222"

    # # # adguardhome
    # # # h3://dns-unfiltered.adguard.com/dns-query
    # # "94.140.14.14"
    # # # "94.140.14.141"
    # # # "94.140.14.141"
  ];

  DoT6 = [
    # # cloudflare
    # "2606:4700:4700:0:0:0:0:1001"
    # # "2606:4700:4700::1111"
    # "2606:4700:4700::64"
    # # "2606:4700:4700::6400"
  ];

  DoT6Proxy = [
    # # google
    # "2001:4860:4860:0:0:0:0:8844"
    # # # quard9
    # # "2620:fe::9"
    # # # adguardhome
    # # "2a00:5a60::ad1:0ff"
    # # "2a00:5a60::ad2:0ff"
  ];

  DoQ = [ ];
  DoQ6 = [ ];

  DoH3 = [ ];
  DoH36 = [ ];

  upBypass = pkgs.writeShellApplication {
    name = "up";
    runtimeInputs = with pkgs; [ ipset iptables ];
    text = ''
      set -x

      ipset list adguardhome_bypass > /dev/null || ipset create adguardhome_bypass hash:ip family inet
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass "+ip) ChinaDoT)}
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass "+ip) DoT)}
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass "+ip) DoH3)}

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820

      iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820 || \
      iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820

      iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820 || \
      iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820
    '';
  };

  upBypass6 = pkgs.writeShellApplication {
    name = "up";
    runtimeInputs = with pkgs; [ ipset iptables ];
    text = ''
      set -x

      ipset list adguardhome_bypass6 > /dev/null || ipset create adguardhome_bypass6 hash:ip family inet6
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 "+ip) ChinaDoT6)}
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 "+ip) DoT6)}
      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 "+ip) DoH36)}

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820

      ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820

      ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820 || \
      ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820
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
    q
    dogdns
    mosdns
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

  systemd.services."mosdns" = {
    description = "mosdns: 一个 DNS 转发器 ";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      StartLimitIntervalSec = 5;
      StartLimitBurst = 10;
    };

    serviceConfig = {
      DynamicUser = true;
      ExecStart = "${pkgs.mosdns}/bin/mosdns start --config ${./mosdns.yaml} --dir /var/lib/mosdns";
      # AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ] ++ optionals cfg.allowDHCP [ "CAP_NET_RAW" ];
      Restart = "always";
      RestartSec = 10;
      RuntimeDirectory = "mosdns";
      StateDirectory = "mosdns";
      LogDirectory = "mosdns";
      # 直连
      ExecStartPre = lib.optionals config.services.v2ray.enable [
        "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m owner --uid-owner mosdns -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner mosdns -j RETURN || true'"
      ];
    };
  };

  systemd.services = {
    "adguardhome" = {
      after = [ "mosdns.service" ];
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
        session_ttl = "719h";
      };

      schema_version = pkgs.adguardhome.schema_version;
      users = [
        inputs.nixos-privates.adguardhome.user
      ];
      dns = {
        # fix: cannot unmarshal !!seq into filtering.BlockedServices
        blocked_services = { };

        # edns_client_subnet = {
        #   enabled = true;
        #   use_custom = true;
        #   custom_ip = "";
        # };

        # v2ray UDP issue https://github.com/v2fly/v2ray-core/issues/68
        bind_hosts = [
          "127.0.0.1"
          "::1"
        ];
        bootstrap_dns = [ ]
          ++ (map (x: "tls://" + x) ChinaDoT)
          ++ (map (x: "tls://[" + x + "]") ChinaDoT6)
        ;
        upstream_dns = [
          # mosdns
          "udp://127.0.0.1:55553"
          "tcp://127.0.0.1:55553"
        ]
        ++ (map (x: "tls://" + x) DoT)
        ++ (map (x: "quic://" + x) DoQ)
        ++ (map (x: "h3://" + x) DoH3)
        ++ (map (x: "tls://[" + x + "]") DoT6)
        ++ (map (x: "quic://[" + x + "]") DoQ6)
        ++ (map (x: "h3://[" + x + "]") DoH36)
        ++ (map (x: "tls://" + x) DoTProxy)
        ++ (map (x: "tls://[" + x + "]") DoT6Proxy)
        #   ++ [
        #   # https://github.com/AdguardTeam/AdGuardHome/issues/3955#issuecomment-1266942407
        #   "h3://cloudflare-dns.com/dns-query"
        # ]
        ++ (
          builtins.filter
            (x: builtins.typeOf x == "string" && x != "" && (builtins.substring 0 1 x) == "[")
            (builtins.split "\n" (builtins.readFile "${inputs.you-know-who}/adguard-home/whitelist_full_combine.txt"))
        );
        # upstream_dns_file = "${inputs.you-know-who}/adguard-home/whitelist_full_combine.txt";
        rewrites = [
          { domain = "challenges.cloudflare.com"; answer = "2606:4700::6812:7b9"; }
          { domain = "chat.openai.com"; answer = "2606:4700::6812:7b9"; }
        ];
        # 
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
