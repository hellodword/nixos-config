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
  additions = final: prev: import ../pkgs { pkgs = final; inherit inputs; };

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = final: prev: {

    # sway-unwrapped = addPatches prev.sway-unwrapped [
    #   # # text_input: Implement input-method popups
    #   # # https://github.com/swaywm/sway/pull/7226
    #   # (prev.fetchpatch {
    #   #   url = "https://github.com/swaywm/sway/commit/d1c6e44886d1047b3aa6ff6aaac383eadd72f36a.patch";
    #   #   hash = "sha256-LsCoK60FKp3d8qopGtrbCFXofxHT+kOv1e1PiLSyvsA=";
    #   # })

    #   # Tray D-Bus Menu
    #   # https://github.com/swaywm/sway/pull/6249
    #   # (prev.fetchpatch {
    #   #   url = "https://github.com/swaywm/sway/commit/2f304ef0532a45d00b2ec2c7fc63adef0aec7607.patch";
    #   #   hash = "sha256-nd+Z6A7GE5Go7QxXOI+hiLWQiXegsQatcNfxEsXgamI=";
    #   # })
    #   ./sway-tray-d-bus-menu.patch
    # ];

    # electron_27 = prev.electron_27.overrideAttrs (oldAttrs: {
    #   buildCommand = prev.lib.replaceStrings
    #     [ "CHROME_DEVEL_SANDBOX $out/libexec/electron/chrome-sandbox" ]
    #     [ "CHROME_DEVEL_SANDBOX /run/wrappers/bin/__${prev.electron_27.pname}-${prev.lib.replaceStrings ["."] ["_"] prev.electron_27.version}-chrome-sandbox" ]
    #     oldAttrs.buildCommand;
    # });

    # vscode = prev.vscode.overrideAttrs (oldAttrs: {
    #   installPhase = prev.lib.replaceStrings
    #     [ "runHook postInstall" ]
    #     [
    #       (prev.lib.concatStringsSep "\n" [
    #         "sed -i \"/ELECTRON=/iVSCODE_PATH='/usr/local/etc/dirty-chrome-sandbox/__${prev.vscode.pname}/lib/vscode'\" \"$out/bin/${prev.vscode.executableName}\""
    #         "runHook postInstall"
    #       ])
    #     ]
    #     oldAttrs.installPhase;
    # });

    feh = prev.feh.overrideDerivation (oldAttrs: {
      postInstall = "sed -i 's/Exec=feh/Exec=feh --scale-down --auto-zoom/' $out/share/applications/feh.desktop";
    });

    sing-box = addPatches prev.sing-box [
      # https://github.com/SagerNet/sing-box/issues/1494
      ./sing-box-http2ping.patch
    ];
  };
}
