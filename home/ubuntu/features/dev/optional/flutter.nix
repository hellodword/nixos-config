{ lib, pkgs, config, persistPath, ... }:

{
  # https://github.com/NixOS/nixpkgs/pull/76420#issuecomment-615344955
  # use nix develop or devcontainers instead

  home.packages = with pkgs; [
    # flutter

    (pkgs.writeShellApplication {
      name = "flutter";
      runtimeInputs = with pkgs; [ android-studio gnugrep ];
      text = ''
        fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.android-studio.outPath}/bin/android-studio)"
        "$fhs" "${pkgs.flutter}/bin/flutter" "$@"
      '';
    })

    (pkgs.writeShellApplication {
      name = "dart";
      runtimeInputs = with pkgs; [ android-studio gnugrep ];
      text = ''
        fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.android-studio.outPath}/bin/android-studio)"
        "$fhs" "${pkgs.flutter}/bin/dart" "$@"
      '';
    })
  ];

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
          ".config/flutte"
          ".dart-tool"
        ];
        files = [
          ".flutter"
        ];
      };
    };
  };
}
