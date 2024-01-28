{ pkgs, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.xfce.thunar;
          profile = "${pkgs.firejail}/etc/firejail/thunar.profile";
        })
      else
        pkgs.xfce.thunar
    )
  ];

  me.mimeApps.defApps.fileBrowser = "thunar.desktop";
}
