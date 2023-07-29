{ lib, inputs, config, pkgs, ... }:

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
  # # 直连
  # systemd.services.adguardhome.serviceConfig.ExecStartPre = lib.optionals config.services.v2ray.enable [
  #   "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m owner --uid-owner adguardhome -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner adguardhome -j RETURN || true'"
  # ];

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
        # v2ray UDP issue https://github.com/v2fly/v2ray-core/issues/68
        bind_hosts = [
          "127.0.0.1"
          "::1"
        ];
        bootstrap_dns = [
          "tls://120.53.53.53"
        ];
        upstream_dns = [
          "tls://1.0.0.1"
          "tls://8.8.4.4"
          "tls://9.9.9.10"
          "tls://[2606:4700:4700:0:0:0:0:1001]"
          "tls://[2001:4860:4860:0:0:0:0:8844]"
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

              "openai.com"
              "*.openai.com"
              "challenges.cloudflare.com"

            ]}/wgcf,wgcf6"
          ];

      };
    };
  };
}
