{ pkgs, ... }:
{

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
      memorySize = 1024;
      cores = 2;
      graphics = false;
    };
  };

  system.stateVersion = "23.05";

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

}
