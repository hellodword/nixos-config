#!/usr/bin/env bash
set -euo pipefail

: "${NIX_IMAGE:?NIX_IMAGE must be set by ./.github/actions/nix-env}"
: "${NIX_CONFIG:?NIX_CONFIG must be set by ./.github/actions/nix-env}"
: "${NIX_USER_CONF_FILES:?NIX_USER_CONF_FILES must be set by ./.github/actions/nix-env}"

docker_args=()
while (($# > 0)); do
  if [[ $1 == -- ]]; then
    shift
    break
  fi
  docker_args+=("$1")
  shift
done

if (($# == 0)); then
  echo 'Usage: nix-container.sh [docker-run-flags...] -- <command> [args...]' >&2
  exit 2
fi

# gawk sizes its pipe table from nofile; bound both descriptor limits.
exec docker run \
  --ulimit nofile=65536:65536 \
  --workdir /workspace \
  --env NIX_USER_CONF_FILES \
  --env NIX_CONFIG \
  --env GIT_CONFIG_COUNT=1 \
  --env GIT_CONFIG_KEY_0=safe.directory \
  --env GIT_CONFIG_VALUE_0=/workspace \
  "${docker_args[@]}" \
  "$NIX_IMAGE" \
  "$@"
