#!/usr/bin/env bash
set -euo pipefail

# Match the existing Docker CI environment; ordinary local checks use the
# host daemon's sandbox setting through the individual Nix outputs.
export NIX_CONFIG="${NIX_CONFIG:-}
sandbox = false
accept-flake-config = false
system-features = nixos-test benchmark big-parallel kvm
max-jobs = 1
cores = 2
"
nix build --no-link --no-update-lock-file \
  .#checks.x86_64-linux.e2e
nix develop --no-update-lock-file --command bash -c '
  set -euo pipefail
  actionlint .github/workflows/check.yml
  shellcheck scripts/ci.sh
  shellcheck -s bash scripts/desktop/screenshot.sh
  find modules home profiles hosts lib nix tests -type f -name "*.nix" -print0 | xargs -0 nixfmt --check
  nixfmt --check flake.nix
  python3 -m tests.integration.cache
'
