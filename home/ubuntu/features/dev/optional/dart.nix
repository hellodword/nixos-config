{ lib, pkgs, config, ... }:

{
  home.packages = with pkgs; [
    dart
  ];

  programs.vscode.extensions = lib.optionals
    config.programs.vscode.enable
    [
      pkgs.vscode-extensions.dart-code.dart-code
    ];
}
