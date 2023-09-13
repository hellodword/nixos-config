{ pkgs, lib, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  services.flameshot = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.flameshot;
          profile = "${pkgs.firejail}/etc/firejail/flameshot.profile";
        })
      else
        pkgs.flameshot;
    settings = {
      # https://github.com/flameshot-org/flameshot/blob/master/flameshot.example.ini
    };
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
    "Print" = "exec flameshot gui";
    "Shift+Print" = "exec flameshot full --clipboard";
  };
}
