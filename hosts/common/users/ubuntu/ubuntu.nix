{ config, ... }:

{
  imports = [
    ./ubuntu-without-password.nix
  ];

  sops.secrets."ubuntu-password" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };

  users.users."ubuntu".hashedPasswordFile = config.sops.secrets."ubuntu-password".path;
}
