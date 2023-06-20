{ lib, inputs, config, pkgs, persistPath, ... }:

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

  environment.persistence = {
    "${persistPath}".directories = [
      "/usr/local/etc/adguard-home"
    ];
  };

  systemd.services.update-adguardhome-upstream-dns-file =
    let
      update-script = pkgs.writeShellApplication {
        name = "fetch-adguardhome-upstream-dns-file";
        runtimeInputs = with pkgs; [ curl coreutils iproute2 ];
        text = ''
          set -x
          set -e
          mkdir -p /usr/local/etc/adguard-home
          cd /usr/local/etc/adguard-home
          INTERFACE=$(ip route | grep '^default' | grep -oP '(?<=dev )[^ \n]+')
          curl --silent --fail \
            --retry 3 \
            --interface "$INTERFACE" \
            --doh-url https://120.53.53.53/dns-query \
            --output /usr/local/etc/adguard-home/whitelist_full_combine.txt.download \
            https://fastly.jsdelivr.net/gh/hellodword/you-know-who@assets/adguard-home/whitelist_full_combine.txt || \
              curl --silent --fail \
                --retry 3 \
                --interface "$INTERFACE" \
                --doh-url https://120.53.53.53/dns-query \
                --output /usr/local/etc/adguard-home/whitelist_full_combine.txt.download \
                https://cdn.jsdelivr.net/gh/hellodword/you-know-who@assets/adguard-home/whitelist_full_combine.txt || \
                  curl --silent --fail \
                    --retry 3 \
                    --output /usr/local/etc/adguard-home/whitelist_full_combine.txt.download \
                    https://cdn.jsdelivr.net/gh/hellodword/you-know-who@assets/adguard-home/whitelist_full_combine.txt
          ln -f whitelist_full_combine.txt.download whitelist_full_combine.txt
        '';
      };
    in
    {
      description = "fetch adguardhome upstream_dns_file";
      after = [
        "network-online.target"
      ]
      ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
      ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ];
      # wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${update-script}/bin/fetch-adguardhome-upstream-dns-file";
        RestartSec = "5m";
        Restart = "on-failure";
      };
    };

  systemd.timers.update-adguardhome-upstream-dns-file = {
    description = "Automatic adguardhome upstream_dns_file fetching";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "24h";
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
        upstream_dns_file = "/usr/local/etc/adguard-home/whitelist_full_combine.txt";
      };
    };
  };
}
