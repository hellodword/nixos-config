# https://github.com/considerate/home/blob/8ff164b1fcf16e233900cc291afc06c8db9aa44f/wallpaper/default.nix#LL3C1-L12C5
{ lib, pkgs, ... }:

{
  services.random-background = {
    enable = true;
    imageDirectory =
      let
        wallpapers = pkgs.runCommand "collect-wallpapers" { } ''
          mkdir $out
          # cp ${pkgs.nixos-artwork.wallpapers.simple-dark-gray.kdeFilePath} $out

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: value: lib.optionalString
                (lib.hasAttrByPath ["kdeFilePath"] value)
                ''cp -f ${value.kdeFilePath} $out/'')
              pkgs.nixos-artwork.wallpapers)};
        '';
      in
      "${wallpapers}";
  };
}
