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
    fcitx5.addons = [
      # https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/system/configuration.nix#L25-L27
      (pkgs.fcitx5-rime.override {
        librime = (pkgs.librime.overrideAttrs (old: {
          buildInputs = old.buildInputs ++ [ pkgs.lua5_4 ];
        })).override {
          plugins = [ pkgs.librime-lua ];
        };
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
