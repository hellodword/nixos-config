{ config, pkgs, persistPath, lib, nixosConfig, ... }:

{
  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/16x16/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/16x16/apps/bitwarden.png";
    ".local/share/icons/hicolor/32x32/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/32x32/apps/bitwarden.png";
    ".local/share/icons/hicolor/64x64/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/64x64/apps/bitwarden.png";
    ".local/share/icons/hicolor/128x128/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/128x128/apps/bitwarden.png";
    ".local/share/icons/hicolor/256x256/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/256x256/apps/bitwarden.png";
    ".local/share/icons/hicolor/512x512/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/512x512/apps/bitwarden.png";
    ".local/share/icons/hicolor/1024x1024/apps/bitwarden.png".source = "${pkgs.bitwarden}/share/icons/hicolor/1024x1024/apps/bitwarden.png";
  };

  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.bitwarden
    )
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/Bitwarden" ];
  };
}
