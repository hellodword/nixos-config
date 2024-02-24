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

  systemd.services = {
    tailscaled-autoconnect = {
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

    tailscaled = {
      serviceConfig = {
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        DynamicUser = true;
      };
    };
  };

  me.sing-box-bypass-services = [
    {
      user = "tailscaled";
      service = "tailscaled";
    }
  ];

  environment.persistence = {
    "${persistPath}".directories = [
      # https://www.reddit.com/r/NixOS/comments/14w1404/every_nixos_rebuild_creates_a_new_tailscale/
      "/var/lib/private/tailscale"
    ];
  };
}
