{ pkgs, lib, config, persistPath, ... }:

{
  # 插件会报错，而且没办法调试，用 nix develop 或者 devcontainer 代替
  # 外部 bash 可以正常运行和调试

  home.packages = [
    # flutter

    (
      # 相当于覆盖 flutter bin ?
      pkgs.symlinkJoin {
        name = "flutter-ass";
        paths = [
          (
            pkgs.writeShellApplication {
              name = "flutter";
              runtimeInputs = with pkgs; [ androidStudioPackages.stable gnugrep ];
              text = ''
                fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.androidStudioPackages.stable.outPath}/bin/android-studio)"
                "$fhs" "${pkgs.flutter}/bin/flutter" "$@"
              '';
            }
          )
          pkgs.flutter
        ];
        # postBuild = ''

        # '';
      }
    )
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
