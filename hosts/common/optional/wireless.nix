{
  lib,
  pkgs,
  config,
  inputs,
  userName,
  ...
}:

let
  secretPath = "wpa_supplicant/wireless.secret";
in
{
  # Wireless secrets stored through sops
  sops.secrets."wireless" = {
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };

  environment.etc."${secretPath}" = {
    enable = true;
    user = "wpa_supplicant";
    group = "wpa_supplicant";
    mode = "0440";
    source = config.sops.secrets."wireless".path;
  };

  # required by wpa_gui
  users.users."${userName}".extraGroups = [ "wpa_supplicant" ];

  networking.wireless = {
    enable = true;
    fallbackToWPA2 = false;
    # Declarative
    secretsFile = "/etc/${secretPath}";
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
    userControlled = true;
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
