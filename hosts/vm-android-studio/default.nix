{ pkgs, lib, ... }: {

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

      diskImage = "./android-studio.qcow2";
      diskSize = 128 * 1024;
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

  environment.systemPackages = [
    pkgs.android-studio
  ];

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "android-studio-stable"
  ];

}
