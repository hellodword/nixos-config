{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
  ];

  qt = {
    enable = true;
    platformTheme = "qt5ct";
    style = "adwaita";
  };
}
