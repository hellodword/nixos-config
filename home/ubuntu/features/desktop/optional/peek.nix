{ pkgs, nixosConfig, lib, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.peek;
          profile = "${pkgs.firejail}/etc/firejail/peek.profile";
        })
      else
        pkgs.peek
    )
  ];
}
