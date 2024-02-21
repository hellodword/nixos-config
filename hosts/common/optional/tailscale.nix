{ config, lib, pkgs, persistPath, ... }:

{
  environment.systemPackages = [
    pkgs.tailscale
  ];

  services.tailscale = {
    enable = true;
    package = pkgs.tailscale;
    authKeyFile = config.sops.secrets."tailscale-auth-key".path;
    extraUpFlags = [
      # https://tailscale.com/kb/1072/client-preferences#in-the-cli
      # block incoming connections
      "--shields-up"
    ];
    interfaceName = "tailscale";
    openFirewall = false;
    # permitCertUid = null;
    port = 41641;
    useRoutingFeatures = "client";
  };

  sops.secrets."tailscale-auth-key" = {
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
  };

  systemd.services.tailscaled-autoconnect = {
    after = lib.mkForce [ "tailscaled.service" ];
    wants = lib.mkForce [ "tailscaled.service" ];
    serviceConfig = {
      AmbientCapabilities = [
        "CAP_NET_ADMIN"
        # TODO minify
        # "CAP_SYS_ADMIN"
      ];
      # DynamicUser = true;
    };
  };

  systemd.services.tailscaled = {
    after = lib.optionals config.services.v2ray.enable [ "v2ray.service" ];
    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      DynamicUser = true;
      # 直连
      ExecStartPre = lib.optionals config.services.v2ray.enable [
        "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m owner --uid-owner tailscaled -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner tailscaled -j RETURN || true'"
      ];
    };
  };

  systemd.services.v2ray.serviceConfig.ExecStartPre = lib.mkAfter [
    "+${pkgs.bash}/bin/bash -c '${pkgs.iptables}/bin/iptables -w 3 -t mangle -C V2RAY_MARK -m owner --uid-owner tailscaled -j RETURN || ${pkgs.iptables}/bin/iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner tailscaled -j RETURN || true'"
  ];

  environment.persistence = {
    "${persistPath}".directories = [
      # https://www.reddit.com/r/NixOS/comments/14w1404/every_nixos_rebuild_creates_a_new_tailscale/
      "/var/lib/private/tailscale"
    ];
  };
}
