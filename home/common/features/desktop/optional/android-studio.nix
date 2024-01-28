{ pkgs, config, persistPath, ... }:

let
  emulator = pkgs.writeShellApplication {
    name = "emulator.sh";
    text = builtins.replaceStrings
      [ "${pkgs.android-studio.unwrapped.outPath}/bin/.studio.sh-wrapped" ]
      [ "${config.home.homeDirectory}/Android/Sdk/emulator/emulator" ]
      (builtins.readFile "${pkgs.android-studio.unwrapped.outPath}/bin/studio.sh");
  };
in
{
  # https://web.archive.org/web/20230626093526/https://forum.manjaro.org/t/android-emulator-performs-extremely-slow/118513/4
  # the default Graphics of AVD is auto, should switch to hardware

  # https://github.com/jo1gi/Config/blob/9ebb02e9e89e659738e36d6f720d6288f08a3049/home/modules/programming/android.nix

  me.allowedUnfreePkg = [
    "android-studio-stable"
    # "android-sdk-cmdline-tools"
    # "android-sdk-tools"
  ];

  # nixpkgs.config = {
  #   android_sdk.accept_license = true;
  # };

  home.sessionVariables = {
    ANDROID_SDK_ROOT = "${config.home.homeDirectory}/Android/Sdk";
    ANDROID_HOME = "${config.home.homeDirectory}/Android/Sdk";
  };

  home.packages = with pkgs; [
    android-studio
    # androidenv.androidPkgs_9_0.androidsdk

    # androidenv.androidPkgs_9_0.emulator
    # # env ANDROID_SDK_ROOT=~/Android/Sdk emulator -netdelay none -netspeed full -no-snapstorage -avd Pixel_6_Pro_API_28 -qt-hide-window -grpc-use-token -idle-grpc-timeout 300

    (pkgs.writeShellApplication {
      name = "emulator";
      runtimeInputs = with pkgs; [ android-studio gnugrep ];
      text = ''
        fhs="$(grep -oP '^[^ ]+-fhs-env' ${pkgs.android-studio.outPath}/bin/android-studio)"
        "$fhs" "${emulator}/bin/emulator.sh" "$@"
      '';
    })
  ];

  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [
        "Android"
        ".cache/Google"
        ".config/Google"
        ".gradle"
        ".android"
        ".local/share/Google" # consentOptions/accepted
        ".jdks"
      ];
    };
  };
}
