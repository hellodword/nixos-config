# https://thekelleys.org.uk/gitweb/?p=dnsmasq.git;a=blob_plain;f=dnsmasq.conf.example;h=f1fb2d10d14b4105b6fb39b85a15098808b50395;hb=refs/tags/v2.90
# https://wiki.archlinux.org/title/Dnsmasq

{
  lib,
  inputs,
  pkgs,
  persistPath,
  ...
}:

let
  dnsmasq = pkgs.dnsmasq.overrideAttrs (oldAttrs: {
    version = "2.91rc1";
    src = pkgs.fetchurl {
      url = "https://www.thekelleys.org.uk/dnsmasq/release-candidates/dnsmasq-2.91rc1.tar.xz";
      hash = "sha256-x5s9Pqnd27siw6UW2tZsqdt3WY6enuACbj9iY0IuIAg=";
    };
    patches = [
      (builtins.fetchurl {
        url = "https://github.com/lixingcong/dnsmasq-regex/raw/refs/heads/master/patches/001-regex-server.patch";
        sha256 = "1zdvnapqspdh4n9i0hmbd6q5jy5np4pr428srkb5qxlk7rsjlcn0";
      })
    ];
    preBuild =
      builtins.replaceStrings [ "-DHAVE_NFTSET" ] [ "-DHAVE_NFTSET -DHAVE_REGEX" ]
        oldAttrs.preBuild;
    buildInputs = oldAttrs.buildInputs ++ [ pkgs.pcre ];
  });

  dnsmasqPort = 5353;
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
    dnsmasq
  ];

  services.dnsmasq = {
    enable = true;
    package = dnsmasq;
    resolveLocalQueries = false;
    settings = {
      port = dnsmasqPort;
      listen-address = [
        "127.0.0.1"
        "::1"
      ];
      no-resolv = true;
      no-poll = true;
      no-hosts = true;
      log-queries = true;
      log-dhcp = true;
      server = [ "127.0.0.1#55553" ];
      conf-dir = "/usr/local/etc/dnsmasq/dnsmasq.d";
    };
  };

  services.resolved = {
    enable = true;
    dnsovertls = "false";
    llmnr = "false";
    fallbackDns = [ "127.0.0.1:${toString dnsmasqPort}" ];
    extraConfig = ''
      DNS=127.0.0.1:${toString dnsmasqPort}
      MulticastDNS=false
    '';
  };

  systemd.services = {
    # dnsmasq = {
    #   serviceConfig = {
    #     ExecStartPre = [
    #       "+${lib.getExe' pkgs.coreutils "mkdir"} -p /usr/local/etc/dnsmasq/dnsmasq.d"
    #     ];
    #   };
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
  };

  me.sing-box-bypass-services = [
    {
      user = "mosdns-cn";
      service = "mosdns-cn";
    }
    {
      user = "systemd-resolve";
      service = "systemd-resolved";
    }
    {
      user = "dnsmasq";
      service = "dnsmasq";
    }
  ];

  environment.persistence = {
    "${persistPath}".directories = [
      {
        directory = "/usr/local/etc/dnsmasq/dnsmasq.d";
      }
    ];
  };
}
