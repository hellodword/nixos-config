{ config, persistPath, ... }:

{
  imports = [
    ./alacritty.nix
    ./kitty.nix
    ./xautolock.nix
  ];

  xdg.mimeApps.enable = true;

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
