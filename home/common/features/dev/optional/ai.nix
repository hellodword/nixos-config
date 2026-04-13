{
  config,
  persistPath,
  ...
}:

{
  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [
        ".codex"
      ];
    };
  };
}
