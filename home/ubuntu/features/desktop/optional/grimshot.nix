{ lib, config, pkgs, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  keybindings = {
    "Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} copy area";
    "${mod}+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} save area";
    "Shift+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} copy screen";
    "${mod}+Shift+Print" = "exec ${lib.getExe pkgs.sway-contrib.grimshot} save screen";
  };
in
{
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
