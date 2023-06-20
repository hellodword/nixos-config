{ pkgs, ... }:

{
  virtualisation.virtualbox.host = {
    enable = true;
    enableHardening = true;
    enableWebService = false;
    package = pkgs.virtualbox;
  };
}
