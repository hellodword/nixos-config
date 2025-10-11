{ inputs, ... }:

{
  # For every flake input, aliases 'pkgs.inputs.${flake}' to
  # 'inputs.${flake}.packages.${pkgs.system}' or
  # 'inputs.${flake}.legacyPackages.${pkgs.system}' or
  flake-inputs = final: _: {
    inputs = builtins.mapAttrs (
      _: flake: (flake.legacyPackages or flake.packages or { }).${final.system} or { }
    ) inputs;
  };

  # Adds my custom packages
  additions = final: prev: import ../pkgs { pkgs = final; };

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications =
    final: prev:
    (
      {

        # # https://github.com/Guanran928/flake/blob/32524d8f91f85936616bb7f0859113dfc3cf46a5/overlays/sway/default.nix
        # sway-unwrapped = prev.sway-unwrapped.overrideAttrs (oldAttrs: {
        #   patches = (oldAttrs.patches or [ ]) ++ [
        #     # https://github.com/swaywm/sway/compare/1.9...NickHu:sway:feature/tray-dbus-menu-1.9.patch
        #     # https://github.com/swaywm/sway/pull/6249#issuecomment-1974771913
        #     (prev.fetchpatch {
        #       name = "tray-dbus-menu-1.9.patch";
        #       url = "https://github.com/swaywm/sway/compare/1.9...NickHu:sway:feature/tray-dbus-menu-1.9.patch";
        #       hash = "sha256-P7ede/4csFycKq5dW9Z5PrqVg+8if3xIm+T8dT4Z7b0=";
        #     })

        #     # https://aur.archlinux.org/cgit/aur.git/tree/?h=sway-im&id=b8434b3ad9e8c6946dbf7b14b0f7ef5679452b94
        #     (prev.fetchpatch {
        #       name = "0001-text_input-Implement-input-method-popups.patch";
        #       url = "https://aur.archlinux.org/cgit/aur.git/plain/0001-text_input-Implement-input-method-popups.patch?h=sway-im&id=b8434b3ad9e8c6946dbf7b14b0f7ef5679452b94";
        #       hash = "sha256-A+rBaWMWs616WllVoo21AJaf9lxg/oCG0b9tHLfuJII=";
        #     })
        #     (prev.fetchpatch {
        #       name = "0002-chore-fractal-scale-handle.patch";
        #       url = "https://aur.archlinux.org/cgit/aur.git/plain/0002-chore-fractal-scale-handle.patch?h=sway-im&id=b8434b3ad9e8c6946dbf7b14b0f7ef5679452b94";
        #       hash = "sha256-YOFm0A4uuRSuiwnvF9xbp8Wl7oGicFGnq61vLegqJ0E=";
        #     })
        #     (prev.fetchpatch {
        #       name = "0003-chore-left_pt-on-method-popup.patch";
        #       url = "https://aur.archlinux.org/cgit/aur.git/plain/0003-chore-left_pt-on-method-popup.patch?h=sway-im&id=b8434b3ad9e8c6946dbf7b14b0f7ef5679452b94";
        #       hash = "sha256-PzhQBRpyB1WhErn05UBtBfaDW5bxnQLRKWu8jy7dEiM=";
        #     })
        #   ];
        # });

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

        feh = prev.feh.overrideAttrs (oldAttrs: {
          postInstall = "sed -i 's/Exec=feh/Exec=feh --scale-down --auto-zoom/' $out/share/applications/feh.desktop";
        });

        # sing-box = prev.sing-box.overrideAttrs (oldAttrs: {
        #   patches = (oldAttrs.patches or [ ]) ++ [
        #     # https://github.com/SagerNet/sing-box/issues/1494
        #     ./sing-box-http2ping.patch
        #   ];
        # });

        mosdns = prev.mosdns.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            ./mosdns-apply-ttl-for-servfail.patch
          ];
          doCheck = false;
        });

        firejail = prev.firejail.overrideAttrs (oldAttrs: {
          src = inputs.firejail;
        });

      }
      // prev.lib.optionalAttrs (inputs.nixpkgs.rev == "c9b6fb798541223bbb396d287d16f43520250518") {

        intel-graphics-compiler = prev.intel-graphics-compiler.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            (prev.fetchpatch {
              name = "pr-449133.patch";
              url = "https://raw.githubusercontent.com/NixOS/nixpkgs/ac194b0e0dd1ad78620bb77c31c6ca54b6ef8caf/pkgs/by-name/in/intel-graphics-compiler/bump-cmake.patch";
              hash = "sha256-w74ET7SVQrIuTuZ0c/eBoEP0EdG7Y0FEAJUxv7KVLvI=";
            })
          ];
        });

      }
    );
}
