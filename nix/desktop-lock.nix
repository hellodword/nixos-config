{ pkgs }:
let
  background =
    pkgs.runCommand "desktop-lock-background.png" { nativeBuildInputs = [ pkgs.librsvg ]; }
      ''
        rsvg-convert ${../data/lockscreen.svg} -o "$out"
      '';
  python = pkgs.python3.withPackages (p: [ p.pillow ]);
in
pkgs.writeShellScriptBin "desktop-lock" ''
  exec ${python.interpreter} ${../scripts/desktop/lock.py} \
    --image ${background} --swaylock ${pkgs.swaylock}/bin/swaylock \
    --i3lock ${pkgs.i3lock}/bin/i3lock --xrandr ${pkgs.xrandr}/bin/xrandr "$@"
''
