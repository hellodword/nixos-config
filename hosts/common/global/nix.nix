{
  lib,
  inputs,
  config,
  ...
}:

{
  nix = {
    # This will add each flake input as a registry
    # To make nix3 commands consistent with your flake
    registry = lib.mapAttrs (_: value: { flake = value; }) inputs;

    # # This will additionally add your inputs to the system's legacy channels
    # # Making legacy nix commands consistent as well, awesome!
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

    # Add nixpkgs input to NIX_PATH
    # This lets nix2 commands still use <nixpkgs>
    # nixPath = [ "nixpkgs=${inputs.nixpkgs.outPath}" ];

    settings = {
      # Enable flakes and new 'nix' command
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Deduplicate and optimize nix store
      auto-optimise-store = true;
      # warn-dirty = false;
      # system-features = [ "kvm" "big-parallel" "nixos-test" ];
    };
  };
}
