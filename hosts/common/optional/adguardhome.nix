{ lib, inputs, config, pkgs, ... }:


let
  # https://dns.iui.im/
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

  startPre = pkgs.writeShellApplication {
    name = "adguardhome.startPre";
    runtimeInputs = with pkgs; [ ipset ];
    text = ''
      ipset list v2ray_bypass > /dev/null || ipset create v2ray_bypass hash:ip family inet

      ${lib.concatStringsSep "\n" (map (ip: "ipset add -! v2ray_bypass "+ip) directIP)}
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

  # ipset
  systemd.services.adguardhome.serviceConfig.AmbientCapabilities = [ "CAP_NET_ADMIN" ];
  # 直连
  systemd.services.adguardhome.serviceConfig.ExecStartPre = lib.optionals config.services.v2ray.enable [
    "+${startPre}/bin/adguardhome.startPre"
  ];

  # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/adguardhome.nix
  services.adguardhome = {
    enable = true;
    extraArgs = [ ];
    mutableSettings = true;
    openFirewall = false;
    settings = {
      bind_host = "127.0.0.1";
      bind_port = 33380;
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
