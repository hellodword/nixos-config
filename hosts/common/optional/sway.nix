{ pkgs, lib, config, persistPath, inputs, ... }:

let
  user = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;
  greetd = false;
in
{
  programs.sway = {
    enable = true;
  };

  ##############################
  ########### greetd ###########
  ##############################

  # require programs.sway.enable for session Sway

  programs.regreet = {
    enable = greetd;
  };

  services.greetd =
    if greetd then
      (
        let
          swayConfig = pkgs.writeText "greetd-sway-config" ''
            # `-l` activates layer-shell mode. Notice that `swaymsg exit` will run after gtkgreet.
            exec "${lib.getExe pkgs.greetd.regreet} -l; swaymsg exit"
            bindsym Mod4+shift+e exec swaynag \
              -t warning \
              -m 'What do you want to do?' \
              -b 'Poweroff' 'systemctl poweroff' \
              -b 'Reboot' 'systemctl reboot'
          '';
        in
        {
          enable = true;
          settings = {
            default_session = {
              command = "${lib.getExe pkgs.sway} --config ${swayConfig}";
            };
          };
        }
      )
    else
      { };

  ##############################
  ############ sddm ############
  ##############################

  # services.xserver.displayManager.defaultSession = "sway";
  services.xserver.enable = !greetd;
  services.xserver.displayManager.sddm =
    if (!greetd) then
      ({
        enable = true;
        wayland.enable = true;
        theme = "catppuccin-mocha";
        settings = {
          Theme.ThemeDir = "${inputs.catppuccin-sddm}/src";
          # Last.User = user;
        };
      })
    else
      { };

  environment.persistence = {
    "${persistPath}".directories =
      if greetd then
        [
          {
            directory = "/var/cache/regreet";
            user = "greeter";
            group = config.users.users."${user}".group;
            mode = "0775";
          }
          {
            directory = "/var/log/regreet";
            user = "greeter";
            group = config.users.users."${user}".group;
            mode = "0775";
          }

          # {
          #   directory = "/var/cache/tuigreet";
          #   user = "greeter";
          #   group = config.users.users."${user}".group;
          #   mode = "0775";
          # }
          # {
          #   directory = "/var/log/tuigreet";
          #   user = "greeter";
          #   group = config.users.users."${user}".group;
          #   mode = "0775";
          # }
        ]
      else
        [
          "/var/lib/sddm"
        ];
  };

}
