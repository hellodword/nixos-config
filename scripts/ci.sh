#!/usr/bin/env bash
set -euo pipefail

# This entrypoint runs inside the CI container. Local checks retain the host
# daemon's sandbox policy through their individual Nix outputs.
base_nix_config="${NIX_CONFIG:-}
sandbox = false
accept-flake-config = false
system-features = nixos-test benchmark big-parallel kvm
"
# The bootstrap needs only Nix; public caches are available before building oranc
# or the development shell. Trust comes from this reviewed checkout.
public_cache_config=$(bash scripts/nix-cache.sh print --public-only)
export NIX_CONFIG="$base_nix_config
$public_cache_config"
state=/ci
operation=${1:-check}
cpus=$(nproc)
jobs=$((cpus < 2 ? cpus : 2))
cores=$((cpus / jobs))
build_options=(--max-jobs "$jobs" --cores "$cores" --no-update-lock-file)

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

if [[ ! -f $state/oranc ]]; then
  oranc_root=$(nix build "${build_options[@]}" --no-link --print-out-paths .#oranc)
  printf '%s\n' "$oranc_root/bin/oranc" > "$state/oranc"
fi
listen=$(nix eval --raw --file nix/cache-config.nix ci.listen)
"$(cat "$state/oranc")" server --listen "$listen" > "$state/oranc.log" 2>&1 &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true' EXIT
for ((attempt = 0; attempt < 50; attempt++)); do
  if (exec 3<>"/dev/tcp/${listen%:*}/${listen##*:}") 2>/dev/null; then break; fi
  kill -0 "$proxy_pid"
  sleep 0.1
done
cache_uri=$(nix eval --raw --file nix/cache-config.nix ci.uri)
if nix store info --store "$cache_uri"; then
  project_cache_config=$(bash scripts/nix-cache.sh print --ci)
  export NIX_CONFIG="$base_nix_config
$project_cache_config"
else
  echo 'Project OCI cache is unavailable; using the configured public caches and local builds.'
fi

if [[ $operation == check ]]; then
  nix develop "${build_options[@]}" --command bash -c '
    set -euo pipefail
    actionlint .github/workflows/ci.yml
    shellcheck scripts/ci.sh scripts/ci/runner.sh scripts/nix-cache.sh
    shellcheck -s bash scripts/desktop/screenshot.sh
    find modules home profiles hosts lib nix tests -type f -name "*.nix" -print0 | xargs -0 nixfmt --check
    nixfmt --check flake.nix
    python3 -m tests.integration.cache
  '
fi

if [[ $operation == check || $operation == final ]]; then
  # This process exits before any product or VM build starts, releasing the
  # evaluator heap. A committed revision gets its own freshly evaluated roots.
  nix eval --no-update-lock-file --json --impure --expr \
    'import ./nix/cache-policy.nix { flake = builtins.getFlake (toString ./.); }' > "$state/policy-next.json"
  mv -- "$state/policy-next.json" "$state/policy.json"
  nix develop "${build_options[@]}" --command bash -c 'command -v python3' > "$state/python"
fi

case "$operation" in
  check) ;;
  dependencies|vm-network-desktop|vm-applications-backup|aggregate)
    "$(cat "$state/python")" -m scripts.ci.build "$operation" --state "$state"
    ;;
  final)
    "$(cat "$state/python")" -m scripts.ci.build all --state "$state" --pass-name committed
    ;;
  *) echo "Unknown CI phase: $operation" >&2; exit 2 ;;
esac
if [[ $operation == aggregate || $operation == final ]]; then
  "$(cat "$state/python")" scripts/ci/cache.py select --state "$state"
fi
