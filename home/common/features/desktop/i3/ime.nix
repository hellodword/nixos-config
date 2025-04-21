{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  keybindings = {
    # 输入法切换冲突
    "${mod}+space" = null;
  };
  fcitx5Theme = ''
    # Theme
    Theme=catppuccin-mocha
    # Dark Theme
    DarkTheme=catppuccin-mocha
  '';
in
{
  i18n.inputMethod = {
    enabled = "fcitx5";
    fcitx5.addons = [
      pkgs.fcitx5-chinese-addons

      pkgs.fcitx5-configtool
      pkgs.fcitx5-gtk
      pkgs.fcitx5-with-addons
    ];
  };

  xdg.configFile."fcitx5" = {
    source = ./fcitx5;
    recursive = true;
    # https://github.com/nix-community/home-manager/issues/1213#issuecomment-626240819
    force = true;
  };

  xdg.configFile."fcitx5/conf/classicui.conf".text = fcitx5Theme;
  home.file.".local/share/fcitx5/conf/classicui.conf".text = fcitx5Theme;
  home.file.".local/share/fcitx5/themes/catppuccin-mocha" = {
    source = inputs.catppuccin-fcitx5 + /src/catppuccin-mocha;
    recursive = true;
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault keybindings;
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
