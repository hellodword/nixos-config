{ lib, pkgs, ... }:

{
  programs.bash.initExtra = lib.mkBefore ''
    source ${pkgs.blesh}/share/blesh/ble.sh
  '';
}
