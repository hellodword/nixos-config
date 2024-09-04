{
  config,
  pkgs,
  persistPath,
  ...
}:

{
  home.packages = with pkgs; [
    remmina
  ];

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [
      ".config/remmina"
      ".local/share/remmina"
      ".config/freerdp"
    ];
  };
}
