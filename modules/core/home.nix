{
  inputs,
  lib,
  userName ? null,
  config,
  ...
}:
let
  cfg = config.site.home;
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];
  options.site.home.enable = lib.mkOption {
    type = lib.types.bool;
    default =
      (config.site.core.enable or false)
      || (config.site.cli.enable or false)
      || (config.site.desktop.enable or false)
      || (config.site.apps.enable or false)
      || (config.site.productivity.enable or false);
    defaultText = lib.literalExpression ''
      (config.site.core.enable or false)
      || (config.site.cli.enable or false)
      || (config.site.desktop.enable or false)
      || (config.site.apps.enable or false)
      || (config.site.productivity.enable or false)
    '';
    description = "Whether to enable the Home Manager user environment.";
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = userName != null && userName != "";
        message = "Enabling site.home requires specialArgs.userName.";
      }
    ];
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
      users.${userName} = {
        imports = [ ../../home ];
        home = {
          username = userName;
          homeDirectory = config.users.users.${userName}.home;
        };
      };
    };
  };
}
