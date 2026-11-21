#!/usr/bin/env bash
set -euo pipefail

: "${NIX_IMAGE:?NIX_IMAGE must be set}"
: "${NIX_CI_STATE:?NIX_CI_STATE must be set}"
: "${NIX_CONFIG:?NIX_CONFIG must be set}"
: "${NIX_USER_CONF_FILES:?NIX_USER_CONF_FILES must be set}"

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
  echo 'Usage: container.sh [docker-run-flags...] -- <command> [args...]' >&2
  exit 2
fi

# Bound soft nofile for gawk while permitting virtiofsd/QEMU to raise up to hard limit.
exec docker run \
  --ulimit nofile=65536:1048576 \
  --workdir /workspace \
  --volume "$NIX_CI_STATE/gitconfig:/root/.gitconfig:ro" \
  --env NIX_USER_CONF_FILES \
  --env NIX_CONFIG \
  "${docker_args[@]}" \
  "$NIX_IMAGE" \
  "$@"
