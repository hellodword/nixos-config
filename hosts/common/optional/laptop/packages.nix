{ pkgs, config, ... }:

let
  mkJailed = import ../../../../modules/common/jailed.nix pkgs;
in
{
  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    pciutils
    sops

    inotify-tools
    colmena
    ffmpeg-full

    librecad

    sqlite
    (
      if config.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.sqlitebrowser;
          profile = "${pkgs.writeText "sqlitebrowser-fixed.profile" ''
            include ${pkgs.firejail}/etc/firejail/sqlitebrowser.profile
            private-etc machine-id
          ''}";
          attr = "postInstall";
        })
      else
        pkgs.sqlitebrowser
    )
  ];
}
