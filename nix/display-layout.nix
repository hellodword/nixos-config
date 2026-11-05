{ pkgs }:
let
  python = pkgs.python3.withPackages (p: [ p.python-xlib ]);
in
pkgs.writeShellScriptBin "site-display-layout" ''
  exec ${python.interpreter} ${../scripts/desktop/layout.py} \
    --autorandr ${pkgs.autorandr}/bin/autorandr \
    --xrandr ${pkgs.xrandr}/bin/xrandr "$@"
''
