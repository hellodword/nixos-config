{ pkgs, lib, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  X = nixosConfig.services.xserver.windowManager.i3.enable;
  keybindings = {
    "Print" = "exec flameshot gui";
    "Shift+Print" = "exec flameshot full --clipboard";
  };
  # https://github.com/flameshot-org/flameshot/issues/2848#issuecomment-1199643659
  flameshotPkg = if X then pkgs.flameshot else
  (pkgs.flameshot.overrideAttrs (o: {
    cmakeFlags = [ "-DUSE_WAYLAND_CLIPBOARD=true" ];
    nativeBuildInputs = o.nativeBuildInputs ++ [ pkgs.libsForQt5.kguiaddons ];
  }));
in
{
  services.flameshot = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = flameshotPkg;
          profile = "${pkgs.firejail}/etc/firejail/flameshot.profile";
        })
      else
        flameshotPkg;
    settings = {
      # https://github.com/flameshot-org/flameshot/blob/master/flameshot.example.ini
    };
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault keybindings;
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
