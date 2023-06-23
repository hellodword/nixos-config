{ pkgs, lib, config, ... }:

let
  mod = "Mod4";
in
{

  # TODO split/refactor


  # home.file.".xinitrc".text = ''
  #   autorandr --change
  #   exec i3
  # '';

  # programs.bash.bashrcExtra = ''
  #   if [ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ]; then
  #     exec ${pkgs.systemd}/bin/systemd-cat -t i3 ${pkgs.xorg.xinit}/bin/startx
  #   fi
  # '';

  imports = [
    ../common

    ./cursor.nix
    ./deadd.nix
    ./i3status.nix
    ./rime.nix
    ./rofi.nix
    ./wallpaper.nix
  ];


  home.packages = with pkgs; [
    alsa-utils
    brightnessctl

    # dmenu
    # networkmanager_dmenu

    # dmenu #application launcher most people use
    i3lock #default i3 screen locker
  ];

  xsession = {
    enable = true;
    # for docker show GUI
    initExtra = ''
      ${pkgs.xorg.xhost}/bin/xhost local:
    '';
  };

  # # for xrdp
  # home.file.".xinitrc" = {
  #   text = ''
  #     ${pkgs.xorg.xhost}/bin/xhost local:
  #   '';
  # };

  xsession.windowManager.i3 = {
    enable = true;
    package = pkgs.i3;
    extraConfig = ''
      title_align center
      default_orientation vertical
    '';
    config = {
      modifier = mod;
      terminal = "kitty";
      # 生成配置后 ws10 会排在第一行，导致默认在 ws10
      defaultWorkspace = "workspace number 1";
      workspaceLayout = "tabbed";

      fonts = {
        names = [ "Jetbrains Mono" ];
        size = 10.0;
      };

      startup = [
        {
          command = "env XMODIFIERS=@im=fcitx QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx fcitx5 -d";
          always = true;
          notification = false;
          workspace = null;
        }
      ];

      keybindings = lib.mkOptionDefault {
        "${mod}+semicolon" = "exec i3lock -c 01544A -n";
        # https://github.com/Th0rgal/horus-nix-home/blob/200c746e2baf5a299ad99756ed32e09a05bcbc1c/configs/i3.nix#L20
        "XF86AudioMute" = "exec amixer set Master toggle";
        "XF86AudioLowerVolume" = "exec amixer set Master 4%-";
        "XF86AudioRaiseVolume" = "exec amixer set Master 4%+";
        "XF86MonBrightnessDown" = "exec brightnessctl set 4%-";
        "XF86MonBrightnessUp" = "exec brightnessctl set 4%+";
      };

      bars = [ ];
    };
  };

}
