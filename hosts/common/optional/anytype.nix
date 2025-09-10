{
  config,
  pkgs,
  persistPath,
  userName,
  ...
}:

let
  mkJailed = import ../../../modules/common/jailed.nix pkgs;
  originalPkg = pkgs.anytype;
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
