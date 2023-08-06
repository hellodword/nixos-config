{ pkgs, ... }:

# not working for flutter
# https://github.com/NixOS/nixpkgs/pull/76420#issuecomment-615344955
let
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    cmdLineToolsVersion = "9.0";
    # toolsVersion = "26.1.1";
    platformToolsVersion = "34.0.1";
    buildToolsVersions = [ "30.0.3" "33.0.2" ];
    includeEmulator = true;
    emulatorVersion = "33.1.6";
    platformVersions = [ "28" "33" ];
    includeSources = false;
    includeSystemImages = true;
    systemImageTypes = [ "default" ];
    abiVersions = [ "armeabi-v7a" "arm64-v8a" "x86" "x86_64" ];
    cmakeVersions = [ "3.22.1" ];
    includeNDK = true;
    ndkVersions = [ "25.2.9519653" ];
    useGoogleAPIs = false;
    useGoogleTVAddOns = false;
    # includeExtras = [
    #   "extras;google;gcm"
    # ];
  };
  androidSdk = androidComposition.androidsdk;
in
{

  me.allowedUnfreePkg = [
    "android-sdk-cmdline-tools"
    "android-sdk-tools"
  ];

  nixpkgs.config = {
    android_sdk.accept_license = true;
  };

  home.sessionVariables = {
    ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
    ANDROID_NDK_ROOT = "${androidComposition.androidsdk}/libexec/android-sdk/ndk-bundle";
  };

  home.packages = with pkgs; [
    androidSdk
    jdk11
  ];
}
