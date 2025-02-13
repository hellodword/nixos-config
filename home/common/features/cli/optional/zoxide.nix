{ config, persistPath, ... }:

{
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    options = [ ];
  };

  home.sessionVariables._ZO_DOCTOR = "0";

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".local/share/zoxide"
    ];
  };
}
