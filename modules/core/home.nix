{
  inputs,
  userName,
  config,
  ...
}:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users.${userName} = {
      imports = [ ../../home ];
      home = {
        username = userName;
        homeDirectory = config.users.users.${userName}.home;
        stateVersion = "22.11";
      };
    };
  };
}
