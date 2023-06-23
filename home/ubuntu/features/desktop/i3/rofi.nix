{ pkgs, config, persistPath, ... }:

{
  home.packages = with pkgs; [
    rofi
    rofi-power-menu
  ];

  # 使用频率影响排序
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".files = [ ".cache/rofi3.druncache" ];
  };
}
