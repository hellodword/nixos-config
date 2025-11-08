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

  # https://github.com/anyproto/anytype-ts/blob/a82c83b24d6364b47f47910fe1a33e3696c48da6/electron/js/menu.js#L564
  environment.variables = {
    ORIGINAL_XDG_CURRENT_DESKTOP = "";
  };

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
