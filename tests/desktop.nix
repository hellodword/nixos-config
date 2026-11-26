{
  pkgs,
  config,
  userName,
}:
let
  home = config.home-manager.users.${userName};
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ./__init__.py
      ./support.py
      ./integration/__init__.py
      ./integration/desktop.py
      ./integration/rule_notifications.py
      ../scripts/desktop/network_rules.py
    ];
  };
  fixtures = pkgs.writeText "desktop-test-settings.json" (
    builtins.toJSON {
      sway = home.xdg.configFile."sway/config".source;
      rofi = home.home.file."${home.xdg.configHome}/rofi/config.rasi".source;
    }
  );
  dbusSessionConf = pkgs.runCommandLocal "desktop-test-dbus-session.conf" { } ''
    sed '/\/etc\/dbus-1/d' ${pkgs.dbus}/share/dbus-1/session.conf > "$out"
  '';
in
pkgs.runCommand "desktop-configuration-and-fonts"
  {
    nativeBuildInputs = with pkgs; [
      (python3.withPackages (p: [ p.dbus-next ]))
      libnotify
      fontconfig
      pango.bin
      dbus
      (import ../nix/sway.nix { inherit pkgs; })
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
    dbus-run-session --config-file ${dbusSessionConf} -- \
      python3 -m tests.integration.rule_notifications
    dbus-run-session --config-file ${dbusSessionConf} -- \
      python3 -m tests.integration.desktop --settings ${fixtures} --output $out
  ''
