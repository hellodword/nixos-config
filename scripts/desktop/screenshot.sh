area=${1:-area}
action=${2:-copy}
case "$area:$action" in
  area:copy|area:save|area:edit|screen:copy|screen:save) ;;
  *) echo 'Usage: desktop-shot [area|screen] [copy|save|edit]' >&2; exit 2 ;;
esac
if [[ "$action" == edit && -z "${WAYLAND_DISPLAY:-}" ]]; then
  exec flameshot gui
fi
shot=$(mktemp --tmpdir="${XDG_RUNTIME_DIR:-/tmp}" screenshot.XXXXXXXX.png)
trap 'rm -f -- "$shot"' EXIT
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  if [[ "$area" == area ]]; then
    geometry=$(slurp) || exit 0
    grim -g "$geometry" "$shot"
  else
    grim "$shot"
  fi
else
  if [[ "$area" == area ]]; then
    maim -s "$shot" || exit 0
  else
    maim "$shot"
  fi
fi
if [[ "$action" == copy ]]; then
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    wl-copy --type image/png < "$shot"
  else
    xclip -selection clipboard -t image/png -i "$shot"
  fi
else
  directory=$(xdg-user-dir PICTURES)
  mkdir -p -- "$directory"
  destination="$directory/screenshot-$(date +%Y%m%d-%H%M%S-%N).png"
  if [[ "$action" == edit ]]; then
    satty --filename "$shot" --output-filename "$destination"
  else
    mv -- "$shot" "$destination"
  fi
fi
