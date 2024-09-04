{
  inputs,
  config,
  lib,
  pkgs,
  persistPath,
  ...
}:

{
  imports = [
    inputs.lanzaboote.nixosModules.lanzaboote
  ];

  boot = {
    # # This should already be here from switching to bootspec earlier.
    # # It's not required anymore, but also doesn't do any harm.
    # bootspec = {
    #   enable = true;
    #   enableValidation = true;
    # };
    lanzaboote = {
      enable = true;
      pkiBundle = "/etc/secureboot";
    };
    # Lanzaboote currently replaces the systemd-boot module.
    # This setting is usually set to true in configuration.nix
    # generated at installation time. So we force it to false
    # for now.
    loader.systemd-boot.enable = lib.mkForce false;
    # loader.grub.enable = lib.mkForce false;
  };

  environment.systemPackages = with pkgs; [
    # For debugging and troubleshooting Secure Boot.
    sbctl
  ];

  environment.persistence."${persistPath}".directories = [ config.boot.lanzaboote.pkiBundle ];
}
