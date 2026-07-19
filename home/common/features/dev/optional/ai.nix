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
        ".agents-viewer"
      ];
    };
  };
}
