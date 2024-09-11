{ pkgs, persistPath, ... }:

{
  services.gnome.gnome-keyring.enable = true;

  programs.sway = {
    enable = true;
  };

  services.dbus.enable = true;
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    # gtk portal needed to make gtk apps happy
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  ##############################
  ############ sddm ############
  ##############################

  environment.systemPackages = [
    (pkgs.catppuccin-sddm.override {
      flavor = "mocha";
      font = "Noto Sans";
      fontSize = "12";
      loginBackground = true;
    })
  ];

  # services.xserver.displayManager.defaultSession = "sway";
  services.xserver.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    package = pkgs.kdePackages.sddm;
    theme = "catppuccin-mocha";
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/sddm"
    ];
  };

}
