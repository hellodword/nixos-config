{ config, pkgs, persistPath, ... }:

{
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/chromium" ];
  };

  programs.chromium = {
    enable = true;
    package = pkgs.chromium;
    commandLineArgs = [ ];
    extensions = [
      { id = "dhdgffkkebhmkfjojejmpbldmpobfkfo"; } # Tampermonkey
      # { id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"; } # ublock origin
    ];
  };
}
