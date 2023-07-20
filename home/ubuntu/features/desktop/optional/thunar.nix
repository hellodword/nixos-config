{ pkgs, ... }:

{
  home.packages = with pkgs; [
    xfce.thunar
  ];

  me.mimeApps.defApps.fileBrowser = "thunar.desktop";
}
