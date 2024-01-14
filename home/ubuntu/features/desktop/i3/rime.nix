{ pkgs, config, lib, nixosConfig, persistPath, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  keybindings = {
    # 输入法切换冲突
    "${mod}+space" = null;
  };
in
{
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      # 使用新的 rimeDataPkgs 的时候要把文件清空
      ".config/ibus/rime"
      ".local/share/fcitx5/rime"
    ];
  };

  i18n.inputMethod = {
    enabled = "fcitx5";
    # fcitx.engines = with pkgs.fcitx-engines; [ rime ];
    # fcitx5.enableRimeData = true;
    fcitx5.addons = with pkgs; [
      (fcitx5-rime.override {
        rimeDataPkgs = [ pkgs.rime-ice ];
      })
    ];
  };

  xdg.configFile."fcitx5" = {
    source = ./fcitx5;
    recursive = true;
    # https://github.com/nix-community/home-manager/issues/1213#issuecomment-626240819
    force = true;
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault keybindings;
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
