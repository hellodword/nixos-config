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
    # 先在 nixos-privates 的 wireless 里添加 ssid
    # psk 在 sops secrets 里， wireless.FOO_PSK
    networks = builtins.listToAttrs (
      map (v: {
        name = v.ssid;
        value = {
          pskRaw = "ext:${v.psk}";
        };
      }) (builtins.attrValues inputs.nixos-privates.wireless)
    );

    # # Imperative
    # allowAuxiliaryImperativeNetworks = true;
    userControlled = {
      enable = true;
      # group = "network";
    };
    extraConfig = ''
      p2p_disabled=1
    '';
  };

  environment.systemPackages = lib.optionals config.services.xserver.enable [
    pkgs.wpa_supplicant_gui
  ];

  # # Ensure group exists
  # users.groups.network = { };
}
