{
  inputs,
  config,
  persistPath,
  ...
}:

{
  imports = [
    inputs.nix-index-database.hmModules.nix-index
  ];

  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".cache/nix-index" ];
  };
}
