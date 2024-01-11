{ config, pkgs, persistPath, nixosConfig, ... }:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = pkgs.bitwarden;
          profile = "${pkgs.firejail}/etc/firejail/bitwarden.profile";
        })
      else
        pkgs.bitwarden
    )
  ];

  me.exitProcess = [
    "bitwarden"
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/Bitwarden" ];
  };
}
