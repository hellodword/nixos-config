{ pkgs, config, persistPath, ... }:

{
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
