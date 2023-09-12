{ nixosConfig, lib, pkgs, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/16x16/apps/mpv.png".source = "${pkgs.mpv}/share/icons/hicolor/16x16/apps/mpv.png";
    ".local/share/icons/hicolor/32x32/apps/mpv.png".source = "${pkgs.mpv}/share/icons/hicolor/32x32/apps/mpv.png";
    ".local/share/icons/hicolor/64x64/apps/mpv.png".source = "${pkgs.mpv}/share/icons/hicolor/64x64/apps/mpv.png";
    ".local/share/icons/hicolor/128x128/apps/mpv.png".source = "${pkgs.mpv}/share/icons/hicolor/128x128/apps/mpv.png";
    ".local/share/icons/hicolor/scalable/apps/mpv.svg".source = "${pkgs.mpv}/share/icons/hicolor/scalable/apps/mpv.svg";
    ".local/share/icons/hicolor/symbolic/apps/mpv-symbolic.svg".source = "${pkgs.mpv}/share/icons/hicolor/symbolic/apps/mpv-symbolic.svg";
  };

  programs.mpv = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        null;
    bindings = { };
  };

  me.mimeApps.defApps.mediaPlayer = "mpv.desktop";
}
