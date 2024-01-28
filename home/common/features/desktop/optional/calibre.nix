{ pkgs, ... }:

{
  home.packages = with pkgs; [
    calibre
  ];

  me.mimeApps.defApps.reader = "calibre.desktop";
}
