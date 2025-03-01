{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    pciutils
    sops

    inotify-tools
    colmena
  ];
}
