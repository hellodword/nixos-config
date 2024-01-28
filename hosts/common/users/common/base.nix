{ config, userName, ... }:

{
  imports = [
    ./without-password.nix
  ];

  sops.secrets."${userName}-password" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
    neededForUsers = true;
  };

  users.users."${userName}".hashedPasswordFile = config.sops.secrets."${userName}-password".path;
}
