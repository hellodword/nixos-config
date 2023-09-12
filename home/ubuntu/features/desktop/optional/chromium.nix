{ lib, config, pkgs, persistPath, nixosConfig, ... }:

{
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/chromium" ];
  };

  home.file = lib.optionalAttrs nixosConfig.programs.firejail.enable {
    ".local/share/icons/hicolor/16x16/apps/chromium.png".source = "${pkgs.chromium}/share/icons/hicolor/16x16/apps/chromium.png";
    ".local/share/icons/hicolor/32x32/apps/chromium.png".source = "${pkgs.chromium}/share/icons/hicolor/32x32/apps/chromium.png";
    ".local/share/icons/hicolor/64x64/apps/chromium.png".source = "${pkgs.chromium}/share/icons/hicolor/64x64/apps/chromium.png";
    ".local/share/icons/hicolor/128x128/apps/chromium.png".source = "${pkgs.chromium}/share/icons/hicolor/128x128/apps/chromium.png";
    ".local/share/icons/hicolor/256x256/apps/chromium.png".source = "${pkgs.chromium}/share/icons/hicolor/256x256/apps/chromium.png";
  };

  programs.chromium = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (builtins.elemAt
          (builtins.filter (x: x.meta.name == "firejail-wrapped-binaries") nixosConfig.environment.systemPackages)
          0)
      else
        pkgs.chromium;
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
