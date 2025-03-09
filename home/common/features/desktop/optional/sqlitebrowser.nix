{ pkgs, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
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
