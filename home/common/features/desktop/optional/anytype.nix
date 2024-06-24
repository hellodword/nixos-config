{ config, pkgs, persistPath, lib, ... }:

{
  home.packages = [ pkgs.anytype ];

  me.allowedUnfreePkg = [ (lib.getName pkgs.anytype) ];

  me.exitProcess = [ "anytype" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/anytype" ];
  };
}
