{ lib, pkgs, ... }:

{
  programs.bash.initExtra = lib.mkAfter ''
    source ${pkgs.blesh}/share/blesh/ble.sh
  '';
}
