{ pkgs }:
{
  copy = pkgs.writeShellApplication {
    name = "desktop-copy";
    runtimeInputs = [
      pkgs.wl-clipboard
      pkgs.xclip
    ];
    text = ''
      if [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
        clipboard=(wl-copy)
      else
        clipboard=(xclip -selection clipboard)
      fi
      if (( $# )); then
        printf '%s' "$*" | "''${clipboard[@]}"
      else
        "''${clipboard[@]}"
      fi
    '';
  };
  shot = pkgs.writeShellApplication {
    name = "desktop-shot";
    runtimeInputs = with pkgs; [
      coreutils
      xdg-user-dirs
      grim
      slurp
      maim
      wl-clipboard
      xclip
      satty
      flameshot
    ];
    text = builtins.readFile ../scripts/desktop/screenshot.sh;
  };
  power = pkgs.writeShellApplication {
    name = "desktop-power";
    runtimeInputs = [
      pkgs.rofi
      pkgs.systemd
    ];
    text = ''
      action=$(printf '%s\n' Lock Suspend Log-out Reboot Power-off | rofi -dmenu -p Session) || exit 0
      case "$action" in
        Lock) loginctl lock-session ;;
        Suspend) systemctl suspend ;;
        Log-out|Reboot|Power-off)
          confirm=$(printf '%s\n' Cancel Confirm | rofi -dmenu -p "$action") || exit 0
          [[ "$confirm" == Confirm ]] || exit 0
          case "$action" in
            Log-out) loginctl terminate-session "$XDG_SESSION_ID" ;;
            Reboot) systemctl reboot ;;
            Power-off) systemctl poweroff ;;
          esac
          ;;
      esac
    '';
  };
  tailscale = pkgs.writeShellApplication {
    name = "desktop-tailscale";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.python3
    ];
    text = ''exec python3 ${../scripts/desktop/tailscale_status.py} "$@"'';
  };
}
