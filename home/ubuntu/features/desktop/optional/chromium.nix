{ lib, config, pkgs, persistPath, ... }:

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

  # flutter debugger or other apps need this
  home.sessionVariables.CHROME_EXECUTABLE = lib.mkOverride 100 "${config.programs.chromium.package}/bin/chromium";
}
