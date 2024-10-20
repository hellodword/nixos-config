{
  lib,
  inputs,
  pkgs,
  persistPath,
  ...
}:

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
    # # google
    # "8.8.4.4"
    "8.8.8.8"

    # # cloudflare
    "1.1.1.1"

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

  # upBypass = pkgs.writeShellApplication {
  #   name = "up";
  #   runtimeInputs = with pkgs; [
  #     ipset
  #     iptables
  #   ];
  #   text = ''
  #     set -x

  #     ipset list adguardhome_bypass > /dev/null || ipset create adguardhome_bypass hash:ip family inet
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass " + ip) ChinaDoT)}
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass " + ip) DoT)}
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass " + ip) DoH3)}

  #     iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

  #     iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

  #     iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820

  #     iptables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820

  #     iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 53  -j MARK --set-mark 41820

  #     iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 53  -j MARK --set-mark 41820

  #     iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p tcp --dport 853 -j MARK --set-mark 41820

  #     iptables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820 || \
  #     iptables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass dst -p udp --dport 443 -j MARK --set-mark 41820
  #   '';
  # };

  # upBypass6 = pkgs.writeShellApplication {
  #   name = "up";
  #   runtimeInputs = with pkgs; [
  #     ipset
  #     iptables
  #   ];
  #   text = ''
  #     set -x

  #     ipset list adguardhome_bypass6 > /dev/null || ipset create adguardhome_bypass6 hash:ip family inet6
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 " + ip) ChinaDoT6)}
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 " + ip) DoT6)}
  #     ${lib.concatStringsSep "\n" (map (ip: "ipset add -! adguardhome_bypass6 " + ip) DoH36)}

  #     ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

  #     ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

  #     ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820

  #     ip6tables -t mangle -C OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I OUTPUT     -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820

  #     ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 53  -j MARK --set-mark 41820

  #     ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 53  -j MARK --set-mark 41820

  #     ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p tcp --dport 853 -j MARK --set-mark 41820

  #     ip6tables -t mangle -C PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820 || \
  #     ip6tables -t mangle -I PREROUTING -m set --match-set adguardhome_bypass6 dst -p udp --dport 443 -j MARK --set-mark 41820
  #   '';
  # };

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

  systemd.services = {
    adguardhome = {
      # description = "AdGuard Home: Network-level blocker";
      # after = [ "network.target" "mosdns.service" ];
      # wantedBy = [ "multi-user.target" ];
      # unitConfig = {
      #   StartLimitIntervalSec = 5;
      #   StartLimitBurst = 10;
      # };

      serviceConfig =
        # let
        #   myArgs = lib.concatStringsSep " " ([
        #     "--no-check-update"
        #     "--pidfile /run/AdGuardHome/AdGuardHome.pid"
        #     "--work-dir /var/lib/AdGuardHome/"
        #     "--config /var/lib/AdGuardHome/AdGuardHome.yaml"
        #   ] ++ config.services.adguardhome2.extraArgs);
        # in
        {
          # DynamicUser = true;
          # ExecStart = "${pkgs.adguardhome2}/bin/adguardhome ${myArgs}";
          # AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" "CAP_NET_ADMIN" "CAP_NET_RAW" ];
          # Restart = "always";
          # RestartSec = 10;
          # RuntimeDirectory = "AdGuardHome";
          # StateDirectory = "AdGuardHome";

          ExecStartPre = [
            # 直连
            # "+${upBypass}/bin/up"
            # "+${upBypass6}/bin/up"
          ];
        };
    };

    mosdns = {
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
      };
    };
  };

  me.sing-box-bypass-services = [
    {
      user = "mosdns";
      service = "mosdns";
    }
  ];

  # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/adguardhome.nix
  services.adguardhome = {
    enable = true;
    package = pkgs.adguardhome;
    extraArgs = [ ];
    mutableSettings = false;
    openFirewall = false;
    host = "127.0.0.1";
    port = 33380;
    settings = {
      schema_version = 27;

      # fix
      http = {
        address = "127.0.0.1:33380";
        session_ttl = "719h";
        pprof = {
          enabled = false;
        };
      };

      # schema_version = pkgs.adguardhome.schema_version;
      users = [
        inputs.nixos-privates.adguardhome.user
      ];
      dns = {
        aaaa_disabled = false;
        all_servers = true;
        allowed_clients = [ ];
        anonymize_client_ip = false;
        blocked_hosts = [ ];
        bogus_nxdomain = [ ];
        bootstrap_prefer_ipv6 = false;
        cache_optimistic = false;
        cache_size = 4194304;
        cache_ttl_max = 0;
        cache_ttl_min = 0;
        disallowed_clients = [ ];
        dns64_prefixes = [ ];
        edns_client_subnet = {
          custom_ip = "";
          enabled = false;
          use_custom = false;
        };
        enable_dnssec = false;
        fallback_dns = [ ];
        fastest_addr = false;
        fastest_timeout = "1s";
        handle_ddr = true;
        ipset_file = "";
        local_ptr_upstreams = [ ];
        max_goroutines = 300;
        port = 53;
        private_networks = [ ];
        ratelimit = 20;
        ratelimit_subnet_len_ipv4 = 24;
        ratelimit_subnet_len_ipv6 = 56;
        ratelimit_whitelist = [ ];
        refuse_any = true;
        serve_http3 = false;
        serve_plain_dns = true;
        trusted_proxies = [
          "127.0.0.0/8"
          "::1/128"
        ];
        upstream_mode = "parallel";
        upstream_timeout = "10s";
        use_dns64 = false;
        use_http3_upstreams = false;
        use_private_ptr_resolvers = true;

        # fix: cannot unmarshal !!seq into filtering.BlockedServices
        blocked_services = { };

        # edns_client_subnet = {
        #   enabled = true;
        #   use_custom = true;
        #   custom_ip = "";
        # };

        bind_hosts = [
          "0.0.0.0"
          "::1"
        ];
        bootstrap_dns = [ ] ++ (map (x: "tls://" + x) ChinaDoT) ++ (map (x: "tls://[" + x + "]") ChinaDoT6);
        # upstream_mode = "parallel";
        upstream_dns =
          [ ]
          ++ (map (x: "tls://" + x) DoT)
          ++ (map (x: "quic://" + x) DoQ)
          ++ (map (x: "h3://" + x) DoH3)
          ++ (map (x: "tls://[" + x + "]") DoT6)
          ++ (map (x: "quic://[" + x + "]") DoQ6)
          ++ (map (x: "h3://[" + x + "]") DoH36)
          ++ (map (x: "tls://" + x) DoTProxy)
          ++ (map (x: "tls://[" + x + "]") DoT6Proxy)
          ++ [
            # mosdns
            "127.0.0.1:55553"
          ]
          #   #   ++ [
          #   #   # https://github.com/AdguardTeam/AdGuardHome/issues/3955#issuecomment-1266942407
          #   #   "h3://cloudflare-dns.com/dns-query"
          #   # ]
          ++ (builtins.filter (x: builtins.isString x && x != "" && (builtins.substring 0 1 x) == "[") (
            builtins.split "\n" (
              builtins.readFile "${inputs.you-know-who}/adguard-home/whitelist_full_combine.txt"
            )
          ))
          ## tailscale magicdns
          # https://tailscale.com/blog/2021-09-private-dns-with-magicdns
          ++ [
            ''[/${
              lib.concatStringsSep "/" [
                "ts.net"
              ]
            }/]100.100.100.100''
          ]
          # 直连
          ++ [
            ''[/${
              lib.concatStringsSep "/" [
                "swcdn.apple.com"
              ]
            }/]https://120.53.53.53:443/dns-query''
          ];
        # upstream_dns_file = "${inputs.you-know-who}/adguard-home/whitelist_full_combine.txt";
        # rewrites = [
        #   { domain = "challenges.cloudflare.com"; answer = "2606:4700::6812:7b9"; }
        #   { domain = "chat.openai.com"; answer = "2606:4700::6812:7b9"; }
        # ];
      };

      auth_attempts = 5;
      block_auth_min = 15;
      clients = {
        runtime_sources = {
          arp = true;
          dhcp = true;
          hosts = true;
          rdns = true;
          whois = true;
        };
      };
      dhcp = {
        enabled = false;
      };

      filtering = {
        blocked_response_ttl = 10;
        blocked_services = {
          schedule = {
            time_zone = "Local";
          };
        };
        blocking_mode = "default";
        cache_time = 30;
        filtering_enabled = true;
        filters_update_interval = 24;
        parental_block_host = "family-block.dns.adguard.com";
        parental_cache_size = 1048576;
        parental_enabled = false;
        protection_enabled = true;
        rewrites = [
          {
            answer = "2606:4700:4400::ac40:961c";
            domain = "chat.openai.com";
          }
          {
            answer = "104.117.182.8";
            domain = "www.msftncsi.com";
          }
          {
            answer = "142.251.40.163";
            domain = "connectivitycheck.gstatic.com";
          }
        ];
        safe_search = {
          enabled = false;
        };
        safebrowsing_block_host = "standard-block.dns.adguard.com";
        safebrowsing_cache_size = 1048576;
        safebrowsing_enabled = false;
        safesearch_cache_size = 1048576;
      };
      filters = [
        {
          enabled = true;
          id = 1;
          name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
        }
        {
          enabled = false;
          id = 2;
          name = "AdAway Default Blocklist";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
        }
      ];
      log = {
        compress = false;
        file = "";
        local_time = false;
        max_age = 3;
        max_backups = 0;
        max_size = 100;
        verbose = false;
      };
      os = {
        group = "";
        rlimit_nofile = 0;
        user = "";
      };
      querylog = {
        enabled = true;
        file_enabled = true;
        ignored = [ ];
        interval = "2160h";
        size_memory = 1000;
      };
      statistics = {
        enabled = true;
        ignored = [ ];
        interval = "24h";
      };
      tls = {
        enabled = false;
      };
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      {
        directory = "/var/lib/private/AdGuardHome";
        user = "adguardhome";
        group = "adguardhome";
        mode = "0755";
      }
    ];
  };
}
