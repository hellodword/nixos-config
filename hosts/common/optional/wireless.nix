{ lib, pkgs, config, ... }:

{
  # Wireless secrets stored through sops
  sops.secrets."wireless" = {
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };

  networking.wireless = {
    enable = true;
    fallbackToWPA2 = false;
    # Declarative
    environmentFile = config.sops.secrets."wireless".path;
    networks = {
      "@HOME_SSID@" = {
        psk = "@HOME_PSK@";
      };
    };


    # # Imperative
    # allowAuxiliaryImperativeNetworks = true;
    userControlled = {
      enable = true;
      # group = "network";
    };
    # extraConfig = ''
    #   update_config=1
    # '';
  };

  environment.systemPackages = lib.optionals config.services.xserver.enable [ pkgs.wpa_supplicant_gui ];

  # # Ensure group exists
  # users.groups.network = { };
}
