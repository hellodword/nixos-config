{ config, pkgs, persistPath, ... }:

{
  environment.systemPackages = [
    pkgs.tailscale
  ];

  # https://kiprey.github.io/2023/11/tailscale-derp/#%E5%85%AD%E3%80%81DERP-%E6%90%AD%E5%BB%BA%E6%80%BB%E7%BB%93%E6%BC%94%E7%A4%BA
  services.tailscale = {
    enable = true;
    package = pkgs.tailscale;
    authKeyFile = config.sops.secrets."tailscale-auth-key".path;
    extraUpFlags = [
      # https://tailscale.com/kb/1072/client-preferences#in-the-cli
      # block incoming connections when --shields-up=true
      "--shields-up=true"
      "--accept-routes=false"
      "--stateful-filtering=false"
    ];
    # interfaceName = "tailscale";
    openFirewall = false;
    # permitCertUid = null;
    # port = 41641;
    useRoutingFeatures = "client";
  };

  sops.secrets."tailscale-auth-key" = {
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
  };

  # use specific User for bypassing sing-box tun
  # DynamicUser not working because tailscaled-autoconnect will use `system_bus_socket`
  # https://github.com/NixOS/nixpkgs/blob/a71aec5f3ae3d6c13d51d45952365e8721e8af4d/nixos/modules/services/networking/tailscale.nix#L116
  # see https://github.com/systemd/systemd/issues/22737
  systemd.services = {
    tailscaled = {
      serviceConfig = {
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          # TODO minify
          "CAP_SYS_ADMIN"
        ];
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
      # "/var/lib/tailscale"
    ];
  };
}
