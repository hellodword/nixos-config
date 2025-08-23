{
  config,
  pkgs,
  persistPath,
  nixosConfig,
  inputs,
  ...
}:

let
  nixpkgs-anytype = import inputs.nixpkgs-anytype {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  mkJailed = import ../../../../../modules/common/jailed.nix pkgs;
  originalPkg = nixpkgs-anytype.anytype;
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
