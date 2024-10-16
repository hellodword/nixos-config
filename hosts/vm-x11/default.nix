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

      diskImage = "./x11.qcow2";
      diskSize = 256 * 1024;
    };
  };

  system.stateVersion = "23.05";

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  services.xrdp.enable = true;
  services.xrdp.defaultWindowManager = "startplasma-x11";
  services.xrdp.openFirewall = true;

  environment.systemPackages = with pkgs; [
    bitwarden
    joplin-desktop
  ];

}
