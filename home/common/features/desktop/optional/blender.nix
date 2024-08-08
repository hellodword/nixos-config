{ config, pkgs, persistPath, ... }:

{
  home.packages = [ pkgs.blender ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/blender" ];
  };
}
