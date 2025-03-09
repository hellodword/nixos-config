{ pkgs, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  programs.feh = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.feh;
          profile = "${pkgs.firejail}/etc/firejail/feh.profile";
          attr = "postInstall";
        })
      else
        pkgs.feh;
    buttons = { };
    keybindings = {
      quit = [
        "C-q"
        "C-w"
        "Escape"
      ];
    };
  };

  me.mimeApps.defApps.imageViewer = "feh.desktop";

  programs.bash.shellAliases = {
    "feh" = "feh --scale-down --auto-zoom";
  };
}
