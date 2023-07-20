{ inputs, lib, pkgs, config, outputs, persistPath, ... }:

{
  imports = [
    inputs.impermanence.nixosModules.home-manager.impermanence
    ../features/cli
    ./sops.nix
  ] ++ (builtins.attrValues outputs.homeManagerModules);

  # https://github.com/nix-community/home-manager/tree/master/modules/programs
  # https://nix-community.github.io/home-manager/options.html

  nixpkgs = {
    overlays = builtins.attrValues outputs.overlays;
  };

  nix = {
    package = lib.mkDefault pkgs.nix;
    settings = {
      experimental-features = [ "nix-command" "flakes" "repl-flake" ];
      warn-dirty = false;
    };
  };

  programs = {
    home-manager.enable = true;
    git.enable = true;
  };

  home = {
    homeDirectory = lib.mkDefault "/home/${config.home.username}";
    stateVersion = lib.mkDefault "22.11";
    sessionPath = [ "$HOME/.local/bin" ];

    persistence = {
      "${persistPath}${config.home.homeDirectory}" = {
        directories = [
          ".local/bin"
        ];
        allowOther = true;
      };
    };
  };
}
