#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-cache.sh print [--public-only | --ci] [--config-file <path>] [--fragment-name <name>]
       nix-cache.sh install [--system] [--public-only] [--config-file <path>] [--fragment-name <name>]

print emits the declared caches as nix.conf settings.
install writes a managed fragment and includes it from the user's or system's nix.conf.
--system installs into NIX_CONF_DIR (default /etc/nix); run as root for a daemon.
--public-only omits the host's local OCI proxy. --ci selects CI's loopback proxy.
EOF
}

operation=""
scope=local
system=false
config_file=""
fragment_name=""

while (($# > 0)); do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    print | install)
      if [[ -n $operation ]]; then
        usage >&2
        exit 2
      fi
      operation=$1
      shift
      ;;
    --public-only)
      scope=public
      shift
      ;;
    --ci)
      scope=ci
      shift
      ;;
    --system)
      system=true
      shift
      ;;
    --config-file)
      config_file=${2:-}
      if [[ -z $config_file ]]; then
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    --fragment-name)
      fragment_name=${2:-}
      if [[ -z $fragment_name ]]; then
        usage >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z $operation || ($operation == print && $system == true) || ($operation == install && $scope == ci) ]]; then
  usage >&2
  exit 2
fi

if [[ -z $config_file ]]; then
  if [[ -f ./nix/cache-config.nix ]]; then
    config_file=./nix/cache-config.nix
  elif [[ -f ./nix/cache.nix ]]; then
    config_file=./nix/cache.nix
  else
    echo "Unable to locate nix/cache-config.nix or nix/cache.nix; pass --config-file." >&2
    exit 2
  fi
fi

if [[ -z $fragment_name ]]; then
  fragment_name="nixos-config-cache.conf"
fi

render() {
  env \
    -u NIXPKGS_CONFIG \
    -u NIXPKGS_ALLOW_BROKEN \
    -u NIXPKGS_ALLOW_INSECURE \
    -u NIXPKGS_ALLOW_UNFREE \
    -u NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM \
    nix --extra-experimental-features nix-command eval --store dummy:// --raw \
    --file "$config_file" "$scope.text"
}

if [[ $operation == print ]]; then
  render
  exit 0
fi

if [[ $system == true ]]; then
  config_dir=${NIX_CONF_DIR:-/etc/nix}
else
  config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/nix
fi

mkdir -p -- "$config_dir"
temporary=$(mktemp "$config_dir/.${fragment_name}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
render > "$temporary"
chmod 644 "$temporary"
mv -- "$temporary" "$config_dir/$fragment_name"

include="include $fragment_name"
if ! grep -Fxq -- "$include" "$config_dir/nix.conf" 2>/dev/null; then
  printf '\n%s\n' "$include" >> "$config_dir/nix.conf"
fi
printf 'Installed cache settings in %s/nix.conf\n' "$config_dir" >&2
if [[ $system == true ]]; then
  printf 'Restart an active nix-daemon to load its updated trust settings.\n' >&2
fi
