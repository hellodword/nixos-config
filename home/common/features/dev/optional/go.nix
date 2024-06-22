{ lib, pkgs, config, ... }:

{
  programs.go = {
    enable = true;
  };

  home.packages = with pkgs; [
    delve # https://github.com/go-delve/delve
    gotools # https://go.googlesource.com/tools
    gopls
    go-outline
    gopkgs
    gomodifytags
    impl
    gotests
    go-tools # installing staticcheck (technically available in golangci-lint, but for use in lsp)
  ];

  programs.vscode.extensions = lib.optionals
    config.programs.vscode.enable
    [
      # pkgs.vscode-extensions.golang.go
    ];

  programs.vscode.userSettings = lib.optionalAttrs
    config.programs.vscode.enable
    {
      "go.toolsManagement.checkForUpdates" = "off";
      "go.toolsManagement.autoUpdate" = false;
      "go.logging.level" = "verbose";
    };

  # https://github.com/void-linux/void-packages/issues/44578
  home.sessionVariables.GOTOOLCHAIN = "local";
}
