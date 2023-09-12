{ pkgs, nixosConfig, lib, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/256x256/apps/sqlitebrowser.png".source = "${pkgs.sqlitebrowser}/share/icons/hicolor/256x256/apps/sqlitebrowser.png";
  };

  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.sqlitebrowser
    )
  ];
}
