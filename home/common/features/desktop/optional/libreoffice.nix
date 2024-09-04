{
  config,
  pkgs,
  persistPath,
  ...
}:

{
  home.packages = with pkgs; [
    libreoffice
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/libreoffice" ];
  };
}
