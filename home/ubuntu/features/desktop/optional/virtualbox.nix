{ config, persistPath, ... }:

{
  # home.packages = with pkgs; [
  #   virtualbox
  # ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/VirtualBox"
      "VirtualBox VMs"
    ];
  };
}
