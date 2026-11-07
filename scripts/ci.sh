#!/usr/bin/env bash
set -euo pipefail

# This entrypoint runs inside the CI container. Local checks retain the host
# daemon's sandbox policy through their individual Nix outputs.
export NIX_CONFIG="${NIX_CONFIG:-}
sandbox = false
accept-flake-config = false
system-features = nixos-test benchmark big-parallel kvm
max-jobs = 1
cores = 2
"
state=/ci
operation=${1:-check}

if [[ $operation == update ]]; then
  nix flake update \
    catppuccin-fcitx5 nixos-hardware plasma-manager sing-box-geosite nixpkgs \
    reproducible-violentmonkey arkenfox-userjs home-manager nix-index-database \
    sing-box-geoip vm-test-tools
  exit
fi

if [[ $operation == publish ]]; then
  "$(cat "$state/python")" scripts/ci/cache.py publish --state "$state"
  exit
fi

oranc_root=$(nix build --no-link --no-update-lock-file --print-out-paths .#oranc)
printf '%s\n' "$oranc_root/bin/oranc" > "$state/oranc"
"$oranc_root/bin/oranc" server --listen 127.0.0.1:37515 > "$state/oranc.log" 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true' EXIT
for ((attempt = 0; attempt < 50; attempt++)); do
  if (exec 3<>/dev/tcp/127.0.0.1/37515) 2>/dev/null; then break; fi
  kill -0 "$proxy_pid"
  sleep 0.1
done
repository=$(nix eval --raw --impure --expr '(builtins.fromJSON (builtins.readFile ./nix/cache-identity.json)).repository')
public_key=$(nix eval --raw --impure --expr '(builtins.fromJSON (builtins.readFile ./nix/cache-identity.json)).publicKey')
cache_uri="http://127.0.0.1:37515/ghcr.io/$repository"
if nix store info --store "$cache_uri"; then
  export NIX_CONFIG="$NIX_CONFIG
extra-substituters = $cache_uri
extra-trusted-public-keys = $public_key
require-sigs = true
"
else
  echo 'Public cache is unavailable; using the official cache and local builds.'
fi

if [[ $operation == check ]]; then
  nix develop --no-update-lock-file --command bash -c '
    set -euo pipefail
    actionlint .github/workflows/ci.yml
    shellcheck scripts/ci.sh scripts/ci/runner.sh
    shellcheck -s bash scripts/desktop/screenshot.sh
    find modules home profiles hosts lib nix tests -type f -name "*.nix" -print0 | xargs -0 nixfmt --check
    nixfmt --check flake.nix
    python3 -m tests.integration.cache
  '
fi

# Prepare source-only dependencies before asking Nix to restore test outputs
# whose reference closures include files we cannot redistribute.
nix eval --json --impure --expr \
  'import ./nix/cache-policy.nix { flake = builtins.getFlake (toString ./.); }' > "$state/policy.json"
nix develop --no-update-lock-file --command bash -c 'command -v python3' > "$state/python"
"$(cat "$state/python")" scripts/ci/cache.py prepare --state "$state"
"$(cat "$state/python")" scripts/ci/cache.py build --state "$state"
"$(cat "$state/python")" scripts/ci/cache.py select --state "$state"
