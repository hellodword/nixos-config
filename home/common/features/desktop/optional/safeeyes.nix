{
  config,
  pkgs,
  persistPath,
  ...
}:

{
  services.safeeyes = {
    enable = true;
    package = pkgs.safeeyes;
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/safeeyes" ];
  };
}
