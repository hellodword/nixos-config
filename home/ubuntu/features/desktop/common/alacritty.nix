{ lib, pkgs, ... }:

let
  # Doing this with IFD is slow, but alacritty doesn't have an `extraConfig` option. :/
  theme = lib.importJSON (pkgs.runCommand "yaml-to-json"
    {
      nativeBuildInputs = [ pkgs.yaml2json ]; # We can only import json data
      src = pkgs.fetchurl {
        name = "alacritty-catpuccin-theme.yaml";
        url = "https://raw.githubusercontent.com/catppuccin/alacritty/c2d27714b43984e47347c6d81216b7670a3fe07f/catppuccin.yml";
        sha256 = "sha256-NFOOBFtLZqoURD4Xv2rtdfG5yvu57MgNddZJX5dZBZU=";
      };
    } ''
    cp $src ./theme.yml
    substituteInPlace ./theme.yml \
      --replace "colors: *macchiato" "colors: *mocha"

    yaml2json < ./theme.yml > $out
  '');
in
{
  # https://github.com/telphan/hestia/blob/49c42528ed7daa62c177e705aa9c06b7b3fbd5b0/home-manager/term.nix
  # https://github.com/IvarWithoutBones/dotfiles/blob/7509fde5b580c41d625ca177bf96b0dec95c197e/home-manager/modules/linux/alacritty.nix
  home.sessionVariables.TERMINAL = "alacritty";

  programs.alacritty = {
    enable = true;

    settings = {
      cursor.style = "Beam";
      inherit (theme) color_schemes colors;

      font = {
        normal = {
          family = "JetBrainsMono Nerd Font";
          style = "Medium";
        };
        size = 11.0;
      };

      window.padding = {
        x = 2;
        y = 2;
      };

      key_bindings = [
        {
          key = "N";
          mods = "Control|Shift";
          action = "SpawnNewInstance";
        }
      ];
    };
  };
}
