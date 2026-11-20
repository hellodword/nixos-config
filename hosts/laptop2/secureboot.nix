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

  environment.etc."sbctl/sbctl.conf".text = lib.mkDefault ''
    keydir: ${config.boot.lanzaboote.pkiBundle}/keys
    guid: ${config.boot.lanzaboote.pkiBundle}/GUID
    files_db: ${config.boot.lanzaboote.pkiBundle}/files.json
    bundles_db: ${config.boot.lanzaboote.pkiBundle}/bundles.json
  '';

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
