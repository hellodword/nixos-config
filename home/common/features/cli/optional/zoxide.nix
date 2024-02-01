{ config, persistPath, ... }:

{
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    options = [ ];
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".local/share/zoxide"
    ];
  };
}
