#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$script_dir/../infra/scripts/nix-cache.sh" \
  --config-file "$script_dir/../nix/cache-config.nix" \
  --fragment-name "nixos-config-cache.conf" \
  "$@"
