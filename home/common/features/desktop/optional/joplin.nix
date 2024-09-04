{
  config,
  pkgs,
  persistPath,
  ...
}:

{
  home.packages = with pkgs; [
    joplin-desktop
  ];

  me.exitProcess = [
    "@joplinapp-desktop"
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/joplin-desktop" ];
  };
}
