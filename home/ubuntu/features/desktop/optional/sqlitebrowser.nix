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
          profile = "${pkgs.firejail}/etc/firejail/sqlitebrowser.profile";
        })
      else
        pkgs.sqlitebrowser
    )
  ];
}
