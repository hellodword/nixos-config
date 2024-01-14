{ outputs, inputs }:

let
  addPatches = pkg: patches: pkg.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ patches;
  });
in
{
  # For every flake input, aliases 'pkgs.inputs.${flake}' to
  # 'inputs.${flake}.packages.${pkgs.system}' or
  # 'inputs.${flake}.legacyPackages.${pkgs.system}' or
  flake-inputs = final: _: {
    inputs = builtins.mapAttrs
      (_: flake: (flake.legacyPackages or flake.packages or { }).${final.system} or { })
      inputs;
  };

  # Adds my custom packages
  additions = final: prev: import ../pkgs { pkgs = final; };

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = final: prev: {
    # example = prev.example.overrideAttrs (oldAttrs: rec {
    # ...
    # });
    sway-unwrapped = addPatches prev.sway-unwrapped [
      # text_input: Implement input-method popups
      # https://github.com/swaywm/sway/pull/7226
      (prev.fetchpatch {
        url = "https://github.com/swaywm/sway/commit/d1c6e44886d1047b3aa6ff6aaac383eadd72f36a.patch";
        hash = "sha256-LsCoK60FKp3d8qopGtrbCFXofxHT+kOv1e1PiLSyvsA=";
      })

      # Tray D-Bus Menu
      # https://github.com/swaywm/sway/pull/6249
      # (prev.fetchpatch {
      #   url = "https://github.com/swaywm/sway/commit/2f304ef0532a45d00b2ec2c7fc63adef0aec7607.patch";
      #   hash = "sha256-nd+Z6A7GE5Go7QxXOI+hiLWQiXegsQatcNfxEsXgamI=";
      # })
      ./sway-tray-d-bus-menu.patch
    ];
  };
}
