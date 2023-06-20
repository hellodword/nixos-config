{ config, pkgs, persistPath, ... }:

{
  home.packages = with pkgs; [
    tor-browser-bundle-bin
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".local/share/tor-browser" ];
  };
}
