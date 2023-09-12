{ pkgs, config, persistPath, nixosConfig, lib, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/128x128/apps/org.pwmt.zathura.png".source = "${pkgs.zathura}/share/icons/hicolor/128x128/apps/org.pwmt.zathura.png";
    ".local/share/icons/hicolor/16x16/apps/org.pwmt.zathura.png".source = "${pkgs.zathura}/share/icons/hicolor/16x16/apps/org.pwmt.zathura.png";
    ".local/share/icons/hicolor/256x256/apps/org.pwmt.zathura.png".source = "${pkgs.zathura}/share/icons/hicolor/256x256/apps/org.pwmt.zathura.png";
    ".local/share/icons/hicolor/32x32/apps/org.pwmt.zathura.png".source = "${pkgs.zathura}/share/icons/hicolor/32x32/apps/org.pwmt.zathura.png";
    ".local/share/icons/hicolor/64x64/apps/org.pwmt.zathura.png".source = "${pkgs.zathura}/share/icons/hicolor/64x64/apps/org.pwmt.zathura.png";
    ".local/share/icons/hicolor/scalable/apps/org.pwmt.zathura.svg".source = "${pkgs.zathura}/share/icons/hicolor/scalable/apps/org.pwmt.zathura.svg";
  };

  programs.zathura = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.zathura;
  };

  me.mimeApps.defApps.reader = "org.pwmt.zathura.desktop";

  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [
        ".local/share/zathura"
      ];
    };
  };
}
