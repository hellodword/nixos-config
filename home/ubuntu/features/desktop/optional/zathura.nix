{ config, persistPath, ... }:

{
  programs.zathura = {
    enable = true;
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
