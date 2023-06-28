{ pkgs, ... }:

{
  # services.xserver = {
  #   enable = true;
  #   displayManager = {
  #     defaultSession = "none";
  #     startx.enable = true;
  #   };
  # };

  # this will use lightdm by default
  services.xserver = {
    enable = true;
    displayManager = {
      defaultSession = "none+i3";
    };
    windowManager.i3 = {
      enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    xorg.xhost
  ];
}
