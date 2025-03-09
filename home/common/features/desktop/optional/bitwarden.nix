{
  config,
  pkgs,
  persistPath,
  nixosConfig,
  ...
}:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  bitwarden-desktop = pkgs.bitwarden-desktop;
  bitwarden-cli = pkgs.bitwarden-cli;
in
{
  home.packages = [
    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = bitwarden-desktop;
          profile = ./bitwarden.profile;
          attr = "postInstall";
        })
      else
        bitwarden-desktop
    )

    (
      if nixosConfig.programs.firejail.enable then
        (mkJailed {
          originalPkg = bitwarden-cli;
          profile = ./bitwarden.profile;
          attr = "postInstall";
          extraArgs = [ "--quiet" ];
        })
      else
        bitwarden-cli
    )
  ];

  me.exitProcess = [
    "bitwarden"
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/Bitwarden"
      ".config/Bitwarden\ CLI"
    ];
  };

  programs.starship = {
    settings = {
      custom = {
        bw_unlocked = {
          command = ''[ -z "$BW_SESSION" ] || echo 🔑🔑🔑 UNLOCKED'';
          require_repo = false;
          when = true;
          ignore_timeout = true;
          style = "bold yellow";
        };
      };
    };
  };
}
