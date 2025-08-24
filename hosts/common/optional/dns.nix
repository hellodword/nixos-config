# https://thekelleys.org.uk/gitweb/?p=dnsmasq.git;a=blob_plain;f=dnsmasq.conf.example;h=f1fb2d10d14b4105b6fb39b85a15098808b50395;hb=refs/tags/v2.90
# https://wiki.archlinux.org/title/Dnsmasq

{
  pkgs,
  lib,
  persistPath,
  ...
}:

let
  dnsmasq = pkgs.dnsmasq.overrideAttrs (oldAttrs: {
    version = "2.91";
    src = pkgs.fetchurl {
      url = "https://www.thekelleys.org.uk/dnsmasq/dnsmasq-2.91.tar.xz";
      hash = "sha256-9iJoKEizNnetsratCCZGGKKuCgHaSGqT/YzZEYaz0VM=";
    };
    patches = [
      (builtins.fetchurl {
        url = "https://github.com/lixingcong/dnsmasq-regex/raw/refs/heads/master/patches/001-regex-server.patch";
        sha256 = "18hk8c1h9s4p860fzf45qqsp71m9135l6v4hxy0xpi39dn49rpzl";
      })
    ];
    preBuild =
      builtins.replaceStrings [ "-DHAVE_NFTSET" ] [ "-DHAVE_NFTSET -DHAVE_REGEX" ]
        oldAttrs.preBuild;
    buildInputs = oldAttrs.buildInputs ++ [ pkgs.pcre ];
  });
in
{

  environment.systemPackages = with pkgs; [
    dig
    knot-dns
    curl
    coreutils
    iproute2
    q
  ];

  services.dnsmasq = {
    enable = true;
    package = dnsmasq;
    resolveLocalQueries = false;
    settings = {
      # port = dnsmasqPort;
      # listen-address = [
      #   "127.0.0.1"
      #   "::1"
      # ];

      # forces dnsmasq to try each query with each server strictly
      # in the order they appear in the config.
      strict-order = true;

      # Never forward plain names (without a dot or domain part)
      domain-needed = true;
      # Never forward addresses in the non-routed address spaces(e.g. private IP).
      bogus-priv = true;
      # don't needlessly read /etc/resolv.conf which only contains the localhost addresses of dnsmasq itself.
      no-resolv = true;

      # Cache dns queries.
      cache-size = 1000;

      # local domains
      local = "/lan/";
      domain = "lan";
      expand-hosts = true;

      # don't use /etc/hosts
      no-hosts = true;
      address = [
        # "/surfer.lan/192.168.10.1"
      ];

      no-poll = true;
      log-queries = true;
      log-dhcp = true;
      server = [ "127.0.0.1#55553" ];
      conf-dir = "/usr/local/etc/dnsmasq/dnsmasq.d";
    };
  };

  services.resolved = {
    enable = lib.mkForce false;
    # dnsovertls = "false";
    # llmnr = "false";
    # fallbackDns = [ "127.0.0.1:${toString dnsmasqPort}" ];
    # extraConfig = ''
    #   DNS=127.0.0.1:${toString dnsmasqPort}
    #   MulticastDNS=false
    # '';
  };

  environment.etc."resolv.conf".text = ''
    nameserver 127.0.0.53
  '';

  systemd.services = {
    dnsmasq = {
      # serviceConfig = {
      #   ExecStartPre = [
      #     "+${lib.getExe' pkgs.coreutils "mkdir"} -p /usr/local/etc/dnsmasq/dnsmasq.d"
      #   ];
      # };
      after = lib.mkForce [ "network.target" ];
    };
    # systemd-resolved = {
    #   before = [ "dnsmasq.service" ];
    # };

    mosdns = {
      description = "mosdns: 一个 DNS 转发器";
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

    mosdns-cn = {
      description = "mosdns: 一个 DNS 转发器（国内）";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = 5;
        StartLimitBurst = 10;
      };

      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.mosdns}/bin/mosdns start --config ${./mosdns-cn.yaml} --dir /var/lib/mosdns-cn";
        # AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ] ++ optionals cfg.allowDHCP [ "CAP_NET_RAW" ];
        Restart = "always";
        RestartSec = 10;
        RuntimeDirectory = "mosdns-cn";
        StateDirectory = "mosdns-cn";
        LogDirectory = "mosdns-cn";
      };
    };

    mosdns-ts = {
      description = "mosdns: 一个 DNS 转发器（TS）";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = 5;
        StartLimitBurst = 10;
      };

      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.mosdns}/bin/mosdns start --config ${./mosdns-ts.yaml} --dir /var/lib/mosdns-ts";
        # AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ] ++ optionals cfg.allowDHCP [ "CAP_NET_RAW" ];
        Restart = "always";
        RestartSec = 10;
        RuntimeDirectory = "mosdns-ts";
        StateDirectory = "mosdns-ts";
        LogDirectory = "mosdns-ts";
      };
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      {
        directory = "/usr/local/etc/dnsmasq/dnsmasq.d";
      }
    ];
  };
}
