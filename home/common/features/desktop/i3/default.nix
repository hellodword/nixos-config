{ pkgs, lib, nixosConfig, config, ... }:

let
  mod = "Mod4";

  X = nixosConfig.services.xserver.windowManager.i3.enable;
  lockCmd = "${if X then "${pkgs.i3lock}/bin/i3lock" else "${pkgs.swaylock}/bin/swaylock -f"} -n -c 01544A";

  extraConfig = (
    ''
      title_align center
      default_orientation vertical
    '' +
    (
      lib.optionalString (!X) ''
        for_window [app_id="flameshot"] border pixel 0, floating enable, fullscreen disable, move absolute position 0 0
        for_window [app_id="wpa_gui"] floating enable
        for_window [app_id="mpv"] floating enable
        for_window [app_id="deadd-notification-center"] move position 1px 1px
        for_window [class="feh"] floating enable
        for_window [class="Emulator"] floating enable
      ''
    )
  );
  i3ConfigStartupExtra = (lib.optionalAttrs X {
    notification = false;
    workspace = null;
  });
  i3Config = {
    modifier = mod;
    terminal = "kitty";
    # 生成配置后 ws10 会排在第一行，导致默认在 ws10
    defaultWorkspace = "workspace number 1";
    workspaceLayout = "tabbed";

    fonts = {
      names = [ "JetBrainsMono Nerd Font" ];
      size = 10.0;
    };

    startup = [
      # (
      #   {
      #     command = "env XMODIFIERS=@im=fcitx QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx fcitx5 -d";
      #     always = true;

      #   } // i3ConfigStartupExtra
      # )
    ]
    ++ (
      [
        {
          # switch to workspace 1 at startup
          command = "${if X then "i3msg" else "swaymsg"} 'workspace number 1'";
          always = false;
        }
      ]
    ) ++ (
      lib.optionals X
        [
          (
            {
              command = "wpa_gui -q -t -i $(iw dev | grep -oP '(?<=Interface ).*$')";
              always = true;
            } // i3ConfigStartupExtra
          )
        ]
    );

    keybindings = lib.mkOptionDefault {
      "${mod}+semicolon" = "exec ${lockCmd}";
      # https://github.com/Th0rgal/horus-nix-home/blob/200c746e2baf5a299ad99756ed32e09a05bcbc1c/configs/i3.nix#L20
      "XF86AudioMute" = "exec amixer set Master toggle";
      "XF86AudioLowerVolume" = "exec amixer set Master 4%-";
      "XF86AudioRaiseVolume" = "exec amixer set Master 4%+";
      "XF86MonBrightnessDown" = "exec brightnessctl set 4%-";
      "XF86MonBrightnessUp" = "exec brightnessctl set 4%+";

      # fix issue from https://github.com/nix-community/home-manager/pull/4636
      "${mod}+0" = null;
      "${mod}+Shift+0" = null;
    };

    bars = [ ]; # if X then [ ] else (lib.mkForce [ ]);
  };
in
{
  imports = [
    ../common

    ./cursor.nix
    (if X then ./deadd.nix else ./mako.nix)
    (if X then ./i3status.nix else ./waybar.nix)
    ./rime.nix
    ./rofi
    ./wallpaper.nix
    ./gtk.nix
  ];


  home.packages = with pkgs; [
    alsa-utils
    brightnessctl

    # networkmanager_dmenu
    # dmenu #application launcher most people use
    # i3lock #default i3 screen locker
  ];

  # # for xrdp
  # home.file.".xinitrc" = {
  #   text = ''
  #     ${pkgs.xorg.xhost}/bin/xhost local:
  #   '';
  # };

  wayland.windowManager.sway = {
    enable = (!X);
    inherit extraConfig;
    config = i3Config;
    wrapperFeatures = {
      gtk = config.gtk.enable;
    };
    extraSessionCommands = ''
      export SDL_VIDEODRIVER=wayland
      export QT_QPA_PLATFORM=wayland
      export QT_WAYLAND_DISABLE_WINDOWDECORATION="1"
      export _JAVA_AWT_WM_NONREPARENTING=1
      export MOZ_ENABLE_WAYLAND=1
    '';
  };

  xsession.enable = X;
  # for docker show GUI
  xsession.initExtra = lib.optionalString X ''
    ${pkgs.xorg.xhost}/bin/xhost local:
  '';
  xsession.windowManager.i3 = {
    enable = X;
    package = pkgs.i3;
    inherit extraConfig;
    config = i3Config;
  };

}
