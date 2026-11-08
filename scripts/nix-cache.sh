#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-cache.sh print [--public-only | --ci]
       nix-cache.sh install [--system] [--public-only]

print emits the declared caches as nix.conf settings.
install writes a managed fragment and includes it from the user's nix.conf.
--system installs into NIX_CONF_DIR (default /etc/nix); run as root for a daemon.
--public-only omits the host's OCI proxy. --ci selects CI's loopback proxy.
EOF
}

operation=${1:-}
if [[ $operation == --help || $operation == -h ]]; then usage; exit; fi
if [[ $operation != print && $operation != install ]]; then usage >&2; exit 2; fi
shift
scope=local
system=false
for argument in "$@"; do
  case "$argument" in
    --public-only) scope=public ;;
    --ci) scope=ci ;;
    --system) system=true ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ $operation == print && $system == true || $operation == install && $scope == ci ]]; then
  usage >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
render() {
  nix --extra-experimental-features nix-command eval --raw \
    --file "$script_dir/../nix/cache-config.nix" "$scope.text"
}
if [[ $operation == print ]]; then render; exit; fi

if [[ $system == true ]]; then
  config_dir=${NIX_CONF_DIR:-/etc/nix}
else
  config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/nix
fi
mkdir -p -- "$config_dir"
temporary=$(mktemp "$config_dir/.nixos-config-cache.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
render > "$temporary"
chmod 644 "$temporary"
mv -- "$temporary" "$config_dir/nixos-config-cache.conf"
include='include nixos-config-cache.conf'
if ! grep -Fxq -- "$include" "$config_dir/nix.conf" 2>/dev/null; then
  printf '\n%s\n' "$include" >> "$config_dir/nix.conf"
fi
printf 'Installed cache settings in %s/nix.conf\n' "$config_dir" >&2
if [[ $system == true ]]; then
  printf 'Restart an active nix-daemon to load its updated trust settings.\n' >&2
fi
