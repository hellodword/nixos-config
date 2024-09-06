{
  config,
  pkgs,
  persistPath,
  nixosConfig,
  ...
}:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  bitwarden = pkgs.bitwarden-desktop;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = bitwarden;
          profile = ./bitwarden.profile;
        })
      else
        bitwarden
    )
  ];

  me.exitProcess = [
    "bitwarden"
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/Bitwarden" ];
  };
}
