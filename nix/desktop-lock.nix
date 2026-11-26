{ pkgs }:
let
  background =
    pkgs.runCommand "desktop-lock-background.png" { nativeBuildInputs = [ pkgs.librsvg ]; }
      ''
        rsvg-convert ${../data/lockscreen.svg} -o "$out"
      '';
in
pkgs.writeShellApplication {
  name = "desktop-lock";
  runtimeInputs = [ pkgs.swaylock ];
  text = ''
    foreground=false
    while (($# > 0)); do
      case "$1" in
        --foreground)
          foreground=true
          shift
          ;;
        *)
          echo "Usage: desktop-lock [--foreground]" >&2
          exit 2
          ;;
      esac
    done

    args=(
      --color 171d35
      --scaling fill
      --inside-color 171d35dd
      --ring-color 89b4fa
      --inside-wrong-color 171d35
      --ring-wrong-color f38ba8
      --key-hl-color cdd6f4
      --text-color cdd6f4
      --image ${background}
    )
    if [[ "$foreground" != true ]]; then
      args+=(--daemonize)
    fi
    exec swaylock "''${args[@]}"
  '';
}
