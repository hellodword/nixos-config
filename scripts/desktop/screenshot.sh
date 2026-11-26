#!/usr/bin/env bash
area=${1:-area}
action=${2:-copy}
case "$area:$action" in
  area:copy|area:save|area:edit|screen:copy|screen:save) ;;
  *) echo 'Usage: desktop-shot [area|screen] [copy|save|edit]' >&2; exit 2 ;;
esac
shot=$(mktemp --tmpdir="${XDG_RUNTIME_DIR:-/tmp}" screenshot.XXXXXXXX.png)
trap 'rm -f -- "$shot"' EXIT
if [[ "$area" == area ]]; then
  geometry=$(slurp) || exit 0
  grim -g "$geometry" "$shot"
else
  grim "$shot"
fi
if [[ "$action" == copy ]]; then
  wl-copy --type image/png < "$shot"
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
