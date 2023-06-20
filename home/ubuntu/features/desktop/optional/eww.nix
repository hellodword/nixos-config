{ pkgs, ... }:

{
  # https://github.com/rxyhn/tokyo/tree/1ab8f91e182a1a5ad9aaaaecaab99d2e97b41baa/config/eww
  # https://github.com/search?q=%2F%5B%5Ea-z%5Cd%5Deww+*%3D%5B%5Cs%5CS%5D%2BconfigDir%2F+language%3Anix&ref=opensearch&type=code
  programs.eww = {
    enable = true;
    package = pkgs.eww;
    # configDir = ewwConf;
  };
}
