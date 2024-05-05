{ pkgs, lib, config, persistPath, inputs, ... }:

{
  # 插件会报错，而且没办法调试，用 nix develop 或者 devcontainer 代替
  # 外部 bash 可以正常运行和调试

  nixpkgs.overlays = [ inputs.flutter-nix.overlays.default ];

  home.packages = [
    pkgs.flutter
  ];

  programs.vscode.userSettings = lib.optionalAttrs
    config.programs.vscode.enable
    {
      "dart.checkForSdkUpdates" = false;
    };

  # https://github.com/NixOS/nixpkgs/pull/76420#issuecomment-615344955
  programs.vscode.extensions = lib.optionals
    config.programs.vscode.enable
    [
      pkgs.vscode-extensions.dart-code.dart-code
      pkgs.vscode-extensions.dart-code.flutter
    ];

  # /home/ubuntu/.config/flutter/tool_state
  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}" = {
        directories = [
          ".config/flutter"
          ".cache/flutter"
          ".dart-tool"
          ".dart"
          ".dartServer"
        ];
        files = [
          ".flutter"
        ];
      };
    };
  };
}
