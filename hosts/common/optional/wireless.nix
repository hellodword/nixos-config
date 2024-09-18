{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:

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
    secretsFile = config.sops.secrets."wireless".path;
    # 先在 nixos-privates 里添加 ssid
    # 再在 secrets 里添加 psk
    networks = {
      "${inputs.nixos-privates.wireless.HOME.ssid}" = {
        pskRaw = "ext:HOME_PSK";
      };
      "${inputs.nixos-privates.wireless.TRAVEL.ssid}" = {
        pskRaw = "ext:TRAVEL_PSK";
      };
      "${inputs.nixos-privates.wireless.IPHONE.ssid}" = {
        pskRaw = "ext:IPHONE_PSK";
      };
      "${inputs.nixos-privates.wireless.MIFI.ssid}" = {
        pskRaw = "ext:MIFI_PSK";
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

  environment.systemPackages = lib.optionals config.services.xserver.enable [
    pkgs.wpa_supplicant_gui
  ];

  # # Ensure group exists
  # users.groups.network = { };
}
