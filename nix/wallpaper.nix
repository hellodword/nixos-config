{ pkgs }:
pkgs.writeShellScriptBin "site-wallpaper" ''
  exec ${pkgs.python3.withPackages (p: [ p.pillow ])}/bin/python3 ${../scripts/desktop/wallpaper.py} \
    --swaymsg ${pkgs.sway}/bin/swaymsg \
    --systemctl ${pkgs.systemd}/bin/systemctl "$@"
''
