{ pkgs, config, persistPath, lib, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
in
{
  # home.packages = with pkgs; [
  #   rofi
  #   rofi-power-menu
  # ];

  # TODO
  programs.rofi = {
    enable = true;
    plugins = with pkgs; [ rofi-calc rofi-emoji rofi-power-menu ];
    terminal = "${pkgs.kitty}/bin/kitty";
    # theme = ./theme.rafi;
  };

  # 使用频率影响排序
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".files = [ ".cache/rofi3.druncache" ];
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
    "${mod}+d" = "exec rofi -modi drun -show drun -drun-show-actions -font 'Jetbrains Mono 16'";
    "${mod}+Shift+d" = "exec rofi -show run -font 'Jetbrains Mono 16'";
    "${mod}+Shift+p" = "exec rofi -show power-menu -modi 'power-menu:rofi-power-menu --choices=shutdown/reboot/logout' -width 20 -lines 3 -font 'Jetbrains Mono 16'";
  };
}
