{
  config,
  pkgs,
  persistPath,
  inputs,
  nixosConfig,
  ...
}:

let
  # package = pkgs.anytype;
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  originalPkg = inputs.anytype-flake.packages.${pkgs.system}.anytype;
  package =
    if nixosConfig.programs.firejail.enable then
      (mkJailed {
        inherit originalPkg;
        profile = ./anytype.profile;
      })
    else
      originalPkg;
in
{
  home.packages = [ package ];

  me.allowedUnfreePkg = [ originalPkg ];

  me.exitProcess = [ "anytype" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/anytype" ];
  };
}
