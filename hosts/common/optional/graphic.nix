{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # 取色
    hyprpicker
    gpick
  ];
}
