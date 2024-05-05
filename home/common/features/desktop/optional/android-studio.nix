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
    androidStudioPackages.stable
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
  ] ++ [
    system-images-android-34-default-arm64-v8a
    system-images-android-34-aosp-atd-arm64-v8a
  ] ++ lib.optionals (lib.strings.hasInfix "x86_64" nixosConfig.nixpkgs.hostPlatform.config) [
    # system-images-android-34-default-x86-64
    # system-images-android-34-aosp-atd-x86-64
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
