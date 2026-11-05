{ inputs, ... }:
{
  imports = [
    inputs.plasma-manager.homeModules.plasma-manager
    ./cli.nix
    ./apps.nix
    ./desktop.nix
  ];
  xdg.enable = true;
}
