{ pkgs, ... }:

let
  mocha = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/catppuccin/alacritty/94800165c13998b600a9da9d29c330de9f28618e/catppuccin-mocha.toml";
    hash = "sha256-/N3rwIZ0SJBiE7TiBs4pEjhzM1f2hr26WXM3ifUzzOY=";
  };

  # https://github.com/myme/dotfiles/blob/931de1db198bdd405c1289d17ded2bcafc230e83/home-manager/wm/alacritty/default.nix
  theme = builtins.fromTOML (builtins.readFile "${mocha}");
in
{
  # https://github.com/telphan/hestia/blob/49c42528ed7daa62c177e705aa9c06b7b3fbd5b0/home-manager/term.nix
  # https://github.com/IvarWithoutBones/dotfiles/blob/7509fde5b580c41d625ca177bf96b0dec95c197e/home-manager/modules/linux/alacritty.nix
  home.sessionVariables.TERMINAL = "alacritty";

  programs.alacritty = {
    enable = true;

    # deprecated https://github.com/alacritty/alacritty/blob/5fdfd47f832522b5fbfa111006046561404789a2/alacritty.yml
    # https://alacritty.org/config-alacritty.html
    settings = {
      cursor.style = "Beam";
      inherit (theme) colors;

      font = {
        normal = {
          family = "monospace";
          style = "Medium";
        };
        size = 11.0;
      };

      window.padding = {
        x = 2;
        y = 2;
      };

      keyboard.bindings = [
        {
          key = "N";
          mods = "Control|Shift";
          action = "SpawnNewInstance";
        }
        #- { key: PageUp,    mods: Shift,   mode: ~Alt,        action: ScrollPageUp   }
        #- { key: PageDown,  mods: Shift,   mode: ~Alt,        action: ScrollPageDown }
        #- { key: Home,      mods: Shift,   mode: ~Alt,        action: ScrollToTop    }
        #- { key: End,       mods: Shift,   mode: ~Alt,        action: ScrollToBottom }
        {
          key = "PageUp";
          mods = "Shift";
          mode = "~Alt";
          action = "ScrollPageUp";
        }
        {
          key = "PageDown";
          mods = "Shift";
          mode = "~Alt";
          action = "ScrollPageDown";
        }
        {
          key = "Home";
          mods = "Shift";
          mode = "~Alt";
          action = "ScrollToTop";
        }
        {
          key = "End";
          mods = "Shift";
          mode = "~Alt";
          action = "ScrollToBottom";
        }
      ];
    };
  };
}
