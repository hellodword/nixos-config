{ config, lib, ... }:

with lib;
with types;
{
  options.me.allowedUnfreePkg = mkOption {
    type = listOf (oneOf [
      str
      package
    ]);
    default = [ ];
  };

  config = {
    nixpkgs.config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) (
        map (x: if typeOf x == "string" then x else (lib.getName x)) config.me.allowedUnfreePkg
      );
  };
}
