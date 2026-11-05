{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    inputs.lanzaboote.nixosModules.lanzaboote
  ];

  boot = {
    lanzaboote = {
      enable = true;
      pkiBundle = "/etc/secureboot";
    };
    # Lanzaboote owns bootloader installation.
    loader.systemd-boot.enable = lib.mkForce false;
  };

  environment.systemPackages = with pkgs; [
    # For debugging and troubleshooting Secure Boot.
    sbctl
  ];

  environment.persistence."${config.site.storage.persistRoot}".directories = [
    {
      directory = config.boot.lanzaboote.pkiBundle;
      mode = "0700";
    }
  ];
}
