{ config, lib, ... }:

with lib;
with types;
{
  options.me.allowedUnfreePkg = mkOption {
    type = listOf str;
    default = [ ];
  };

  config = {
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) config.me.allowedUnfreePkg;
  };
}
