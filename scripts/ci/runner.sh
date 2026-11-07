#!/usr/bin/env bash
# Lifecycle of the dedicated, ephemeral GitHub-hosted runner's Nix store.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]]

case "${1:?prepare, exec, publish or finish}" in
  prepare)
    df -h / /mnt
    # Fixed SDK allowlist. Docker, Git, gh, runner Node and KVM remain available.
    sudo rm -rf -- /usr/local/lib/android /usr/share/dotnet /opt/ghc \
      /usr/local/.ghcup /usr/share/swift /usr/local/share/boost
    df -h / /mnt
    sudo modprobe kvm
    test -c /dev/kvm
    sudo chmod 666 /dev/kvm
    mkdir -p "$RUNNER_TEMP/nixos-ci" "$RUNNER_TEMP/nixos-build"
    docker volume create nixos-ci-store
    # An empty named volume receives the image's existing /nix contents.
    docker run --detach --name nixos-ci --device /dev/kvm \
      --volume nixos-ci-store:/nix \
      --volume "$GITHUB_WORKSPACE:/workspace" \
      --volume "$RUNNER_TEMP/nixos-ci:/ci" \
      --volume "$RUNNER_TEMP/nixos-build:/build" \
      --workdir /workspace --env TMPDIR=/build \
      --env 'NIX_CONFIG=experimental-features = nix-command flakes' \
      "$NIX_IMAGE" sleep infinity
    docker exec nixos-ci git config --global --add safe.directory /workspace
    docker exec --detach nixos-ci bash -c \
      'while true; do date -u +%FT%TZ; df -B1 /nix /build; sleep 60; done >> /ci/disk-usage.log'
    ;;
  exec)
    shift
    docker exec nixos-ci bash scripts/ci.sh "$@"
    ;;
  publish)
    # Names only: Docker reads values from this step's environment.
    docker exec --env ORANC_USERNAME --env ORANC_PASSWORD --env ORANC_SIGNING_KEY \
      nixos-ci bash scripts/ci.sh publish
    ;;
  finish)
    docker logs nixos-ci || true
    if [[ -f $RUNNER_TEMP/nixos-ci/oranc.log ]]; then
      tail -n 80 "$RUNNER_TEMP/nixos-ci/oranc.log"
    fi
    if [[ -f $RUNNER_TEMP/nixos-ci/disk-usage.log ]]; then
      cat "$RUNNER_TEMP/nixos-ci/disk-usage.log"
    fi
    docker rm --force nixos-ci || true
    docker volume rm nixos-ci-store || true
    df -h / /mnt
    ;;
  *) exit 2 ;;
esac
