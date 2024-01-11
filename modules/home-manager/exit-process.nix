{ lib, ... }:

with lib;
with types;
{
  options.me.exitProcess = mkOption {
    type = listOf str;
    default = [ ];
  };
}
