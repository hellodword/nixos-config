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

  # https://github.com/NixOS/nixpkgs/issues/242113#issuecomment-1628379807
  # rm -rf ~/.config/chromium/Default/GPUCache/
  home.activation.fix-issue-244742 = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "${persistPath}${config.home.homeDirectory}/.config/chromium/Default/GPUCache" || true
  '';
}
