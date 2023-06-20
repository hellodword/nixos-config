{ config, pkgs, persistPath, ... }:

{
  home.packages = with pkgs; [
    bitwarden
  ];

  # TODO backup
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/Bitwarden" ];
  };
}
