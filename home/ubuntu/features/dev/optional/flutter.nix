{ lib, pkgs, config, ... }:

{
  home.packages = with pkgs; [
    flutter
  ];

  programs.vscode.extensions = lib.optionals
    config.programs.vscode.enable
    [
      pkgs.vscode-extensions.dart-code.dart-code
      pkgs.vscode-extensions.dart-code.flutter
    ];
}
