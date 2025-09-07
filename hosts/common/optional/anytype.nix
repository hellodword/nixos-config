{
  config,
  pkgs,
  persistPath,
  inputs,
  userName,
  ...
}:

let
  nixpkgs-anytype = import inputs.nixpkgs-anytype {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  mkJailed = import ../../../modules/common/jailed.nix pkgs;
  originalPkg = nixpkgs-anytype.anytype;
  package =
    if config.programs.firejail.enable then
      (mkJailed {
        inherit originalPkg;
        profile = ./anytype.profile;
        attr = "postInstall";
      })
    else
      originalPkg;
in
{
  environment.systemPackages = [ package ];

  me.allowedUnfreePkg = [
    originalPkg
    "anytype-heart"
  ];

  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".config/anytype"
        ];
      };
    };
  };
}
