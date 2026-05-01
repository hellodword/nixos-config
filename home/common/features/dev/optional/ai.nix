{
  # config,
  persistPath,
  ...
}:

{
  home = {
    persistence = {
      "${persistPath}".directories = [
        ".codex"
      ];
    };
  };
}
