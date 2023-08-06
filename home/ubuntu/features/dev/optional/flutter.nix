{ pkgs, config, persistPath, ... }:

{
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
              runtimeInputs = with pkgs; [ android-studio gnugrep ];
              text = ''
                fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.android-studio.outPath}/bin/android-studio)"
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


  # # https://github.com/NixOS/nixpkgs/pull/76420#issuecomment-615344955
  # # 会报错，用 nix develop 或者 devcontainer 代替
  # programs.vscode.extensions = lib.optionals
  #   config.programs.vscode.enable
  #   [
  #     pkgs.vscode-extensions.dart-code.dart-code
  #     pkgs.vscode-extensions.dart-code.flutter
  #   ];

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
