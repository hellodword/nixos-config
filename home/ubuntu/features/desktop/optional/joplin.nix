{ config, pkgs, persistPath, ... }:

{
  home.packages = with pkgs; [
    joplin-desktop
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/joplin-desktop" ];
  };
}
