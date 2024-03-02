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
    sway-unwrapped = prev.sway-unwrapped.overrideAttrs (oldAttrs: {
      version = "1.10-unstable-2024-02-23";
      src = prev.fetchFromGitHub {
        owner = "swaywm";
        repo = "sway";
        rev = "fc640d5f6c82883c35e90a64f0098486e6091293";
        hash = "sha256-n0U1RoSv3fuOkey2gXPX+O4mRA2PCASpkRrIE5069BI";
      };

      buildInputs = with prev; [
        (wlroots.overrideAttrs {
          version = "1.18.0-unstable-2024-02-23";
          src = prev.fetchFromGitLab {
            domain = "gitlab.freedesktop.org";
            owner = "wlroots";
            repo = "wlroots";
            rev = "54e1fefd2e29cb00dff7c02801913d793ceab7d6";
            hash = "sha256-VX2AAzcYl255yF43+uetcOS+uYzAVfk7WccWONpjmYU=";
          };
        })

        cairo
        gdk-pixbuf
        json_c
        libGL
        libdrm
        libevdev
        libinput
        librsvg
        libxkbcommon
        pango
        pcre2
        wayland
        wayland-protocols
        xorg.xcbutilwm
      ];
    });

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
