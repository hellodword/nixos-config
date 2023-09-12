{ pkgs, lib, nixosConfig, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/48x48/apps/flameshot.png".source = "${pkgs.mpv}/share/icons/hicolor/48x48/apps/flameshot.png";
    ".local/share/icons/hicolor/128x128/apps/flameshot.png".source = "${pkgs.mpv}/share/icons/hicolor/128x128/apps/flameshot.png";
    ".local/share/icons/hicolor/scalable/apps/flameshot.svg".source = "${pkgs.mpv}/share/icons/hicolor/scalable/apps/flameshot.svg";
    ".local/share/icons/hicolor/48x48/apps/org.flameshot.Flameshot.png".source = "${pkgs.mpv}/share/icons/hicolor/48x48/apps/org.flameshot.Flameshot.png";
    ".local/share/icons/hicolor/128x128/apps/org.flameshot.Flameshot.png".source = "${pkgs.mpv}/share/icons/hicolor/128x128/apps/org.flameshot.Flameshot.png";
    ".local/share/icons/hicolor/scalable/apps/org.flameshot.Flameshot.svg".source = "${pkgs.mpv}/share/icons/hicolor/scalable/apps/org.flameshot.Flameshot.svg";
  };

  services.flameshot = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.flameshot;
    settings = {
      # https://github.com/flameshot-org/flameshot/blob/master/flameshot.example.ini
    };
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
    "Print" = "exec flameshot gui";
    "Shift+Print" = "exec flameshot full --clipboard";
  };
}
