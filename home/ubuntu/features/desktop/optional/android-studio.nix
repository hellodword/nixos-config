{ pkgs, config, persistPath, ... }:

{
  # https://web.archive.org/web/20230626093526/https://forum.manjaro.org/t/android-emulator-performs-extremely-slow/118513/4
  # the default Graphics of AVD is auto, should switch to hardware

  allowedUnfreePkg = [
    "android-studio-stable"
  ];

  home.packages = with pkgs; [
    android-studio
  ];

  home = {
    persistence = {
      "${persistPath}${config.home.homeDirectory}".directories = [
        "Android"
        ".cache/Google"
        ".config/Google"
        ".gradle"
        ".android"
      ];
    };
  };
}
