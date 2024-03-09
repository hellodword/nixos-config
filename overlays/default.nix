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

    # https://github.com/Guanran928/flake/blob/32524d8f91f85936616bb7f0859113dfc3cf46a5/overlays/sway/default.nix
    sway-unwrapped = addPatches prev.sway-unwrapped [
      # https://github.com/swaywm/sway/compare/1.9...NickHu:sway:feature/tray-dbus-menu-1.9.patch
      # https://github.com/swaywm/sway/pull/6249#issuecomment-1974771913
      (prev.fetchpatch {
        url = "https://github.com/swaywm/sway/compare/1.9...NickHu:sway:feature/tray-dbus-menu-1.9.patch";
        hash = "sha256-JhVqMmXbtmGbM3GmTidrQ/UMSjXRR2wX6sgv3kdUYIQ=";
      })
    ];

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
