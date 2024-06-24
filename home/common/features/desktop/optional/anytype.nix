{ config, pkgs, persistPath, ... }:

{
  home.packages = [ pkgs.anytype ];

  me.allowedUnfreePkg = [ pkgs.anytype ];

  me.exitProcess = [ "anytype" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/anytype" ];
  };
}
