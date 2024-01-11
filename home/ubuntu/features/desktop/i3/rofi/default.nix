{ pkgs, config, persistPath, lib, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  rofi-power-menu-with-check = pkgs.writeShellApplication {
    name = "rofi-power-menu-with-check";
    text = ''
      if ${lib.concatStringsSep " || " (map (x: "[ \"$(pgrep -x \"${x}\")\" ]") config.me.exitProcess)}; then
        ${pkgs.libnotify}/bin/notify-send --urgency critical --expire-time=10000 "关机提示:" "你应该先关闭重要进程!"
      else
        rofi -show power-menu -modi 'power-menu:rofi-power-menu --choices=shutdown/reboot/logout' -width 20 -lines 3 -font 'Jetbrains Mono 16'
      fi
    '';
  };
in
{
  home.packages = with pkgs; [
    # rofi
    rofi-power-menu
  ];

  me.exitProcess = [
    "VBoxSVC"
    "VirtualBoxVM"
  ];

  programs.rofi = {
    enable = true;
    plugins = with pkgs; [ rofi-calc rofi-emoji rofi-power-menu ];
    terminal = "${pkgs.kitty}/bin/kitty";
    # theme = ./theme.rafi;
    extraConfig = {
      disable-history = false;
      show-icons = true;
      sidebar-mode = false;
      sort = true;

      drun-display-format = "{icon} {name}";

      display-drun = "   Run ";
      display-emoji = "   Emoji ";
      display-window = " 﩯 Window ";
      display-power-menu = "  Power Menu ";

      modi = "run,drun,filebrowser,emoji,power-menu:${
          lib.getExe pkgs.rofi-power-menu
        }";

      xoffset = 0;
      yoffset = 0;
    };
  };

  # 使用频率影响排序
  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".files = [ ".cache/rofi3.druncache" ];
  };

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
    "${mod}+d" = "exec rofi -modi drun -show drun -drun-show-actions -font 'Jetbrains Mono 16'";
    "${mod}+Shift+d" = "exec rofi -show run -font 'Jetbrains Mono 16'";
    "${mod}+Shift+p" = "exec ${rofi-power-menu-with-check}/bin/rofi-power-menu-with-check";
  };
}
