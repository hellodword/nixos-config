{ config, lib, ... }:

{
  sops.secrets."ubuntu-password" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };

  users.mutableUsers = false;
  users.users."ubuntu" = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [
      "wheel"
    ]
    # https://github.com/GTrunSec/hive/blob/37b3bb48973ab792b3ead93a8604e663093eae1e/nixos/nixosModules/virtualisation/__config/default.nix#L15-L17
    ++ lib.optionals config.virtualisation.docker.enable [ "docker" ]
    ++ lib.optionals config.virtualisation.podman.enable [ "podman" ]
    ++ lib.optionals config.virtualisation.libvirtd.enable [ "libvirtd" ]
    # VirtualBox is not currently allowed to access USB devices
    ++ lib.optionals config.virtualisation.virtualbox.host.enable [ "vboxusers" ]
    ++ lib.optionals config.hardware.brillo.enable [ "video" ]
    ++ [ ];

    passwordFile = config.sops.secrets."ubuntu-password".path;
  };

  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  services.openssh.settings.PasswordAuthentication =
    if builtins.length config.users.users."ubuntu".openssh.authorizedKeys.keyFiles == 0 &&
      builtins.length config.users.users."ubuntu".openssh.authorizedKeys.keys == 0
    then
      true
    else
      false;
}
