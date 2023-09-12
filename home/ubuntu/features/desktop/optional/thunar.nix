{ pkgs, nixosConfig, lib, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/128x128/apps/org.xfce.thunar.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/128x128/apps/org.xfce.thunar.png";
    ".local/share/icons/hicolor/16x16/apps/org.xfce.thunar.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/16x16/apps/org.xfce.thunar.png";
    ".local/share/icons/hicolor/16x16/stock/navigation/stock_folder-copy.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/16x16/stock/navigation/stock_folder-copy.png";
    ".local/share/icons/hicolor/16x16/stock/navigation/stock_folder-move.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/16x16/stock/navigation/stock_folder-move.png";
    ".local/share/icons/hicolor/24x24/stock/navigation/stock_folder-copy.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/24x24/stock/navigation/stock_folder-copy.png";
    ".local/share/icons/hicolor/24x24/stock/navigation/stock_folder-move.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/24x24/stock/navigation/stock_folder-move.png";
    ".local/share/icons/hicolor/48x48/apps/org.xfce.thunar.png".source = "${pkgs.xfce.thunar}/share/icons/hicolor/48x48/apps/org.xfce.thunar.png";
    ".local/share/icons/hicolor/scalable/apps/org.xfce.thunar.svg".source = "${pkgs.xfce.thunar}/share/icons/hicolor/scalable/apps/org.xfce.thunar.svg";
  };

  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.xfce.thunar
    )
  ];

  me.mimeApps.defApps.fileBrowser = "thunar.desktop";
}
