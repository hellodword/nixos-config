{ pkgs, ... }:
{

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  users.users = {
    admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      password = "admin";
    };
  };

  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      graphics = true;

      diskImage = "./wayland.qcow2";
      diskSize = 256 * 1024;
    };
  };

  system.stateVersion = "23.05";

  boot.kernelPackages = pkgs.linuxPackages_6_6;

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };

  services.xserver.enable = false;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.desktopManager.plasma6.enable = true;
}
