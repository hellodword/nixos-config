{ config, pkgs, persistPath, ... }:

{
  home.packages = with pkgs; [
    bitwarden
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/Bitwarden" ];
  };
}
