{ pkgs, config }:
let
  home = config.home-manager.users.ubuntu;
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ./__init__.py
      ./support.py
      ./integration/__init__.py
      ./integration/desktop.py
    ];
  };
  fixtures = pkgs.writeText "desktop-test-settings.json" (
    builtins.toJSON {
      sway = home.xdg.configFile."sway/config".source;
      i3 = home.xdg.configFile."i3/config".source;
    }
  );
in
pkgs.runCommand "desktop-configuration-and-fonts"
  {
    nativeBuildInputs = with pkgs; [
      python3
      fontconfig
      pango.bin
      dbus
      (import ../nix/sway.nix { inherit pkgs; })
      i3
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf {
      fontDirectories = config.fonts.packages;
      impureFontDirectories = [ ];
      includes = map (p: "${p}/etc/fonts/conf.d") config.fonts.fontconfig.confPackages;
    };
    WLR_BACKENDS = "headless";
    WLR_RENDERER = "pixman";
  }
  ''
    cp -r ${source}/. .
    mkdir -p $out
    dbus-run-session --config-file ${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 -m tests.integration.desktop --settings ${fixtures} --output $out
  ''
