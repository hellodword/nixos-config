{
  pkgs,
  lib,
  config,
  persistPath,
  ...
}:

let
  flutterAss = pkgs.symlinkJoin {
    name = "flutter-ass";
    meta = pkgs.flutter.meta;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = pkgs.flutter.passthru // {
      # Update the SDK attribute.
      # This allows any modified SDK files to be included
      # in future invocations.
      sdk = flutterAss;
    };
    paths = [
      (pkgs.writeShellApplication {
        name = "flutter";
        runtimeInputs = with pkgs; [
          android-studio
          gnugrep
        ];
        text = ''
          fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.android-studio.outPath}/bin/android-studio)"
          "$fhs" "${pkgs.flutter}/bin/flutter" "$@"
        '';
      })
      pkgs.flutter
      pkgs.flutter.cacheDir
      pkgs.flutter.sdk
    ];
    postBuild = ''
      wrapProgram "$out/bin/flutter" \
        --set-default FLUTTER_ROOT "$out"

      if [ ! -d "$out/.git" ]; then
        # symlinkJoin seems to be missing the .git directory for some reason.
        if [ -d '${pkgs.flutter.sdk}/.git' ]; then
          ln -s '${pkgs.flutter.sdk}/.git' "$out"
        fi
      fi
    '';
  };
in
{
  home.packages = [
    # pkgs.flutter
    flutterAss
  ];

  programs.vscode.profiles.default.userSettings = lib.optionalAttrs config.programs.vscode.enable {
    "dart.checkForSdkUpdates" = false;
  };

  # https://github.com/NixOS/nixpkgs/pull/76420#issuecomment-615344955
  programs.vscode.profiles.default.extensions = lib.optionals config.programs.vscode.enable [
    pkgs.vscode-extensions.dart-code.dart-code
    pkgs.vscode-extensions.dart-code.flutter
  ];

  # programs.bash.initExtra = lib.mkAfter ''
  #   source <(flutter bash-completion)
  # '';

  # /home/ubuntu/.config/flutter/tool_state
  home = {
    persistence = {
      "${persistPath}" = {
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
