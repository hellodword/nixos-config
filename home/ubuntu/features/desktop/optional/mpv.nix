{ nixosConfig, pkgs, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  programs.mpv = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.mpv;
          profile = "${pkgs.firejail}/etc/firejail/mpv.profile";
        })
      else
        pkgs.mpv;
    bindings = { };
  };

  me.mimeApps.defApps.mediaPlayer = "mpv.desktop";
}
