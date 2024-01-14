{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    gnome.adwaita-icon-theme
  ];

  qt = {
    enable = true;
    platformTheme = "qt5ct";
    style = "adwaita";
  };
}
