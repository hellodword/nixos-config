{
  config,
  pkgs,
  persistPath,
  nixosConfig,
  ...
}:

let
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  originalPkg = pkgs.anytype;
  package =
    if nixosConfig.programs.firejail.enable then
      (mkJailed {
        inherit originalPkg;
        profile = ./anytype.profile;
        attr = "postInstall";
      })
    else
      originalPkg;
in
{
  home.packages = [ package ];

  me.allowedUnfreePkg = [
    originalPkg
    "anytype-heart"
  ];

  me.exitProcess = [ "anytype" ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/anytype" ];
  };
}
