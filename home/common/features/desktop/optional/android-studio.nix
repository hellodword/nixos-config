{ pkgs, config, persistPath, inputs, lib, nixosConfig, ... }:

{
  imports = [
    inputs.android-nixpkgs.hmModule
  ];

  nixpkgs.overlays = [ inputs.android-nixpkgs.overlays.default ];

  me.allowedUnfreePkg = [
    "android-studio-stable"
    # "android-sdk-cmdline-tools"
    # "android-sdk-tools"
  ];

  home.packages = with pkgs; [
    jdk
    gradle
    android-studio
  ];

  android-sdk.enable = true;

  # Optional; default path is "~/.local/share/android".
  android-sdk.path = "${config.home.homeDirectory}/.android/sdk";

  android-sdk.packages = sdkPkgs: with sdkPkgs; [
    build-tools-34-0-0
    cmdline-tools-latest
    emulator
    platforms-android-34
    sources-android-34
    platform-tools
  ] ++ lib.optionals (lib.strings.hasInfix "x86_64" nixosConfig.nixpkgs.hostPlatform.config) [
    # https://android.googlesource.com/platform/external/qemu/+/refs/heads/aosp-emu-34-dev/android/emulator/main-emulator.cpp#1080
    system-images-android-27-default-arm64-v8a
    # system-images-android-27-google-apis-arm64-v8a

    system-images-android-34-default-x86-64
    system-images-android-34-aosp-atd-x86-64
  ] ++ [
    # for flutter
    # build-tools;30.0.3
    build-tools-30-0-3
    tools
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
