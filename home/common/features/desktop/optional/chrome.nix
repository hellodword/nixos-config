{ lib, config, persistPath, pkgs, ... }:

{
  me.allowedUnfreePkg = [ pkgs.google-chrome ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/google-chrome" ];
  };

  programs."google-chrome" = {
    enable = true;
    commandLineArgs = [ ];
    # https://github.com/nix-community/home-manager/blob/d1f04b0f365a34896a37d9015637796537ec88a3/modules/programs/chromium.nix#L184
  };

  # flutter debugger or other apps need this
  home.sessionVariables.CHROME_EXECUTABLE = lib.mkOverride 1000 "${config.programs."google-chrome".package}/bin/google-chrome-stable";
}
