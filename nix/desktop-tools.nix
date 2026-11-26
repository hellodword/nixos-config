{ pkgs, rofi }:
{
  copy = pkgs.writeShellApplication {
    name = "desktop-copy";
    runtimeInputs = [ pkgs.wl-clipboard ];
    text = ''
      if (($# > 0)); then
        printf '%s' "$*" | wl-copy
      else
        wl-copy
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
      wl-clipboard
      satty
    ];
    text = builtins.readFile ../scripts/desktop/screenshot.sh;
  };
  power = pkgs.writeShellApplication {
    name = "desktop-power";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${../scripts/desktop/power.py} \
        --rofi ${rofi}/bin/rofi --systemctl ${pkgs.systemd}/bin/systemctl \
        --swaymsg ${pkgs.sway}/bin/swaymsg \
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
