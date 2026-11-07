{ pkgs, rofi }:
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
      pkgs.python3
    ];
    text = ''
      exec python3 ${../scripts/desktop/power.py} \
        --rofi ${rofi}/bin/rofi --systemctl ${pkgs.systemd}/bin/systemctl \
        --swaymsg ${pkgs.sway}/bin/swaymsg --i3msg ${pkgs.i3}/bin/i3-msg \
        --busctl ${pkgs.systemd}/bin/busctl "$@"
    '';
  };
  lock = import ./desktop-lock.nix { inherit pkgs; };
  tailscale = pkgs.writeShellApplication {
    name = "desktop-tailscale";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.python3
    ];
    text = ''exec python3 ${../scripts/desktop/tailscale_status.py} "$@"'';
  };
}
