{
  # config,
  # persistPath,
  nixosConfig,
  lib,
  ...
}:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
in
{
  imports = [
    ./kitty.nix
    ./alacritty.nix
    ./autolock.nix
    ./keyring.nix
  ]
  ++ (lib.optionals X [ ./autorandr.nix ]);

  # xdg.mimeApps.enable = true;
  me.mimeApps.enable = true;
}
