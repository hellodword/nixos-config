{ config, pkgs, persistPath, ... }:

{
  home.packages = with pkgs; [
    joplin-desktop
  ];

  # TODO backup
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/joplin-desktop" ];
  };
}
