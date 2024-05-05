{ pkgs, config, persistPath, ... }:

let
  sdkArgs = {
    abiVersions = [ "arm64-v8a" "x86_64" ];
    # buildToolsVersions = [ ];
    # cmakeVersions = [ ];
    # cmdLineToolsVersion = [ ];
    # emulatorVersion = "";
    # Accepting more licenses declaratively:
    extraLicenses = [
      # Already accepted for you with the global accept_license = true or
      # licenseAccepted = true on androidenv.
      # "android-sdk-license"

      # These aren't, but are useful for more uncommon setups.

      # curl -sSL https://github.com/NixOS/nixpkgs/raw/nixos-unstable/pkgs/development/mobile/androidenv/repo.json | grep -oP '"[^"\n,]+-license"' | sort -u
      "android-googletv-license"
      "android-sdk-arm-dbt-license"
      "android-sdk-license"
      "android-sdk-preview-license"
      "google-gdk-license"
      "intel-android-extra-license"
      "intel-android-sysimage-license"
      "mips-android-sysimage-license"
    ];
    includeEmulator = true;
    includeExtras = [
      "extras;android;m2repository"
      "extras;google;m2repository"
      # "extras;google;gcm"
    ];
    includeNDK = false;
    includeSources = false;
    includeSystemImages = true;
    # ndkVersions = [ ];
    # platformToolsVersion = "";
    platformVersions = [ "34" ];
    systemImageTypes = [ "google_apis" ];
    # toolsVersion = "";
    useGoogleAPIs = false;
    useGoogleTVAddOns = false;
  };

  androidComposition = pkgs.androidenv.composeAndroidPackages sdkArgs;

  androidSdk = androidComposition.androidsdk;
  platformTools = androidComposition.platform-tools;
  jdk = pkgs.jdk;
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

  nixpkgs.config = {
    android_sdk.accept_license = true;
  };

  home.sessionVariables = rec {
    # Note: ANDROID_HOME is deprecated. Use ANDROID_SDK_ROOT.
    ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
    ANDROID_NDK_ROOT = "${ANDROID_SDK_ROOT}/ndk-bundle";
  };

  home.packages = [
    androidSdk
    platformTools
    jdk
    pkgs.android-studio
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
