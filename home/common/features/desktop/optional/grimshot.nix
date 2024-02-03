{ lib, config, pkgs, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  keybindings = {
    "Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} copy area";
    "${mod}+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} save area ~/Pictures/grimshot-area-$(date +\"%Y-%m-%d-%H-%M-%S-%N\").png";
    "Shift+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} copy screen";
    "${mod}+Shift+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} save screen ~/Pictures/grimshot-screen-$(date +\"%Y-%m-%d-%H-%M-%S-%N\").png";
  };
in
{
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
