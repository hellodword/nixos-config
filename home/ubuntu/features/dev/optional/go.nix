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
  ];

  programs.vscode.extensions = lib.optionals
    config.programs.vscode.enable
    [
      pkgs.vscode-extensions.golang.go
    ];
}
