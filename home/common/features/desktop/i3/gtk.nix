{ config, pkgs, ... }:

{
  gtk = {
    enable = true;

    gtk2.configLocation = "${config.xdg.configHome}/gtk-2.0/gtkrc";


    # fix red sad face tray icon of rime/fcitx5
    # https://github.com/swaywm/sway/issues/5645
    iconTheme = {
      name = "Adwaita";
      package = pkgs.gnome.adwaita-icon-theme;
    };

    theme = {
      name = "adw-gtk3";
      package = pkgs.adw-gtk3;
    };
  };
}
