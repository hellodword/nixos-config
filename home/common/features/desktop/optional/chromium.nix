{
  lib,
  config,
  pkgs,
  persistPath,
  nixosConfig,
  ...
}:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.persistence = {
    "${persistPath}".directories = [ ".config/chromium" ];
  };

  me.exitProcess = [
    "chromium"
  ];

  programs.chromium = {
    enable = true;
    package =
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.chromium;
          profile = "${pkgs.firejail}/etc/firejail/chromium.profile";
          attr = "buildCommand";
        })
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
  home.activation.fix-issue-244742-chromium = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -rf "${persistPath}${config.home.homeDirectory}/.config/chromium/Default/GPUCache" || true
  '';
}
