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
      config.site.core.enable
      || config.site.cli.enable
      || config.site.desktop.enable
      || config.site.apps.enable
      || config.site.productivity.enable;
    defaultText = lib.literalExpression ''
      config.site.core.enable
      || config.site.cli.enable
      || config.site.desktop.enable
      || config.site.apps.enable
      || config.site.productivity.enable
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
