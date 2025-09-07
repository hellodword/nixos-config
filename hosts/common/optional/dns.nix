# https://thekelleys.org.uk/gitweb/?p=dnsmasq.git;a=blob_plain;f=dnsmasq.conf.example;h=f1fb2d10d14b4105b6fb39b85a15098808b50395;hb=refs/tags/v2.90
# https://wiki.archlinux.org/title/Dnsmasq

{
  pkgs,
  lib,
  config,
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

      # https://www.thomasaldrian.net/linux-mobile/2023/03/06/dnscrypt/
      listen-address = "127.0.0.53";
      bind-interfaces = true;

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
      serviceConfig = {
        ExecStartPre = [
          "+${lib.getExe' pkgs.coreutils "mkdir"} -p /usr/local/etc/dnsmasq/dnsmasq.d"
        ]
        ++ (lib.optionals config.services.tailscale.enable [
          "+${lib.getExe pkgs.bashInteractive} -c 'echo server=/ts.net/100.100.100.100 > /usr/local/etc/dnsmasq/dnsmasq.d/01-ts.conf'"
        ]);
      };
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
  };

  systemd.services."update-dnsmasq-rule" = {
    after = [
      "dnsmasq.service"
      "sing-box.service"
    ];
    path = with pkgs; [
      bashInteractive
      curl
      jq
      coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Restart = "on-failure";
      RestartSec = "5m";
    };
    script =
      let
        update-dnsmasq-rule = pkgs.writeShellApplication {
          name = "update-dnsmasq-rule";
          text = ''
            mkdir -p /usr/local/etc/dnsmasq/dnsmasq.d

            DATA_CN_ORI="$(cat /usr/local/etc/dnsmasq/dnsmasq.d/99-cn.conf || true)"
            echo "fetching cn..."
            DATA_CN_NEW="$(${../../../scripts/generate-dnsmasq.sh} | sort -u)"
            if [ "$DATA_CN_NEW" != "$DATA_CN_ORI" ]; then
              echo "updating cn..."
              echo "$DATA_CN_NEW" > /usr/local/etc/dnsmasq/dnsmasq.d/99-cn.conf
            fi

            DATA_NCN_ORI="$(cat /usr/local/etc/dnsmasq/dnsmasq.d/98-ncn.conf || true)"
            echo "fetching ncn..."
            DATA_NCN_NEW="$(env NCN=true ${../../../scripts/generate-dnsmasq.sh} | sort -u)"
            if [ "$DATA_NCN_NEW" != "$DATA_NCN_ORI" ]; then
              echo "updating ncn..."
              echo "$DATA_NCN_NEW" > /usr/local/etc/dnsmasq/dnsmasq.d/98-ncn.conf
            fi

            if [ "$DATA_CN_NEW" != "$DATA_CN_ORI" ] || [ "$DATA_NCN_NEW" != "$DATA_NCN_ORI" ]; then
              echo "rebooting..."
              systemctl restart dnsmasq
            fi
          '';
        };
      in
      "${update-dnsmasq-rule}/bin/update-dnsmasq-rule";
  };
  systemd.timers."update-dnsmasq-rule" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      Unit = "update-dnsmasq-rule.service";
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
