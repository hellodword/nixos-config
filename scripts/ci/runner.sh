#!/usr/bin/env bash
# Lifecycle of the dedicated, ephemeral GitHub-hosted runner's Nix store.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true ]]
state="$RUNNER_TEMP/nixos-ci"

case "${1:?prepare, exec, publish or finish}" in
  prepare)
    mkdir -p "$state" "$RUNNER_TEMP/nixos-build"
    date -u +%FT%TZ > "$state/started"
    df -h / /mnt
    # Fixed SDK allowlist. Docker, Git, gh, runner Node and KVM remain available.
    sudo rm -rf -- /usr/local/lib/android /usr/share/dotnet /opt/ghc \
      /usr/local/.ghcup /usr/share/swift /usr/local/share/boost
    df -h / /mnt
    # Job-owned swap supplements the runner's existing swap. It is released
    # after the build container, so no active builder depends on it at cleanup.
    sudo fallocate -l 8G "$state/swap"
    sudo chmod 600 "$state/swap"
    sudo mkswap "$state/swap"
    sudo swapon "$state/swap"
    free -h
    sudo modprobe kvm
    test -c /dev/kvm
    sudo chmod 666 /dev/kvm
    docker volume create nixos-ci-store
    # An empty named volume receives the image's existing /nix contents.
    docker run --detach --name nixos-ci --device /dev/kvm \
      --volume nixos-ci-store:/nix \
      --volume "$GITHUB_WORKSPACE:/workspace" \
      --volume "$state:/ci" \
      --volume "$RUNNER_TEMP/nixos-build:/build" \
      --workdir /workspace --env TMPDIR=/build \
      --env 'NIX_CONFIG=experimental-features = nix-command flakes' \
      "$NIX_IMAGE" sleep infinity
    docker exec nixos-ci git config --global --add safe.directory /workspace
    container_pid=$(docker inspect --format '{{.State.Pid}}' nixos-ci)
    python3 -m scripts.ci.report monitor --state "$state" --container-pid "$container_pid" \
      > "$state/monitor.log" 2>&1 &
    ;;
  exec)
    shift
    python3 -m scripts.ci.report run --state "$state" --phase "$1" -- \
      docker exec nixos-ci bash scripts/ci.sh "$@"
    ;;
  publish)
    # Names only: Docker reads values from this step's environment.
    python3 -m scripts.ci.report run --state "$state" --phase publish -- \
      docker exec --env ORANC_USERNAME --env ORANC_PASSWORD --env ORANC_SIGNING_KEY \
        nixos-ci bash scripts/ci.sh publish
    ;;
  finish)
    touch "$state/monitor.stop"
    # Capture cgroup counters before removing the container; a killed child
    # does not necessarily set Docker's container-level OOMKilled flag.
    if container_pid=$(docker inspect --format '{{.State.Pid}}' nixos-ci); then
      python3 -m scripts.ci.report sample --state "$state" --container-pid "$container_pid" || true
      docker inspect --format '{{json .State}}' nixos-ci
    fi
    if [[ -f $state/started ]]; then
      sudo journalctl -k --since "$(cat "$state/started")" --utc --no-pager -o short-iso \
        --grep='(?i)out of memory|killed process|oom' 2>&1 | tee "$state/oom-kernel.log" > /dev/null || true
      sudo journalctl -u systemd-oomd --since "$(cat "$state/started")" --utc --no-pager -o short-iso \
        2>&1 | tee "$state/oom-userspace.log" > /dev/null || true
    fi
    docker logs nixos-ci || true
    if [[ -f $state/oranc.log ]]; then
      tail -n 80 "$state/oranc.log"
    fi
    if [[ -f $state/resources.jsonl ]]; then
      cat "$state/resources.jsonl"
    fi
    if [[ -f $state/timings.jsonl ]]; then
      cat "$state/timings.jsonl"
    fi
    summary_status=0
    python3 -m scripts.ci.report summary --state "$state" | tee -a "$GITHUB_STEP_SUMMARY" || summary_status=$?
    docker rm --force nixos-ci || true
    docker volume rm nixos-ci-store || true
    if [[ -f $state/swap ]]; then
      # A failed prepare may have created the file without activating it.
      if swapon --show=NAME --noheadings --raw | grep -Fxq "$state/swap"; then
        sudo swapoff "$state/swap"
      fi
      sudo rm -- "$state/swap"
    fi
    df -h / /mnt
    exit "$summary_status"
    ;;
  *) exit 2 ;;
esac
