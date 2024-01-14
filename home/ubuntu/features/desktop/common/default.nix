{ config, persistPath, nixosConfig, lib, ... }:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
in
{
  imports = [
    ./alacritty.nix
    ./kitty.nix
    ./autolock.nix
  ] ++ (lib.optionals X [ ./autorandr.nix ]);

  # xdg.mimeApps.enable = true;
  me.mimeApps.enable = true;

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}" = {
      directories = [
        # 个人文件
        "Desktop"
        "Documents"
        "Downloads"
        "Music"
        "Pictures"
        "Videos"
      ];
      allowOther = true;
    };
  };
}
