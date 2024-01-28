{ pkgs, ... }:

{
  home.packages = with pkgs; [
    eww-tray
  ];
}
