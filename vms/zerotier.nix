{ pkgs, lib, ... }: {

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

  boot.kernelPackages = pkgs.linuxPackages_6_6;

  nix.settings.experimental-features = [ "nix-command" "flakes" "repl-flake" ];

  environment.systemPackages = with pkgs; [
    vim
    iptables
    iproute2
    python3
    zerotierone
  ];

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];

}
