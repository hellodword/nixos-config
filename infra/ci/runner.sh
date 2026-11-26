#!/usr/bin/env bash
# Host and container lifecycle subcommands for verify and update composite actions.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
NIX_DEFAULT_IMAGE="docker.io/nixos/nix@sha256:53b5ec518b696373829ea305c3c07a8c870113e44648c88ec484ef078550fd4f"

cmd_init() {
  local update_mode=false
  if [[ "${1:-}" == "--update" ]]; then
    update_mode=true
  fi

  local project_dir run_tag state build_tmp oranc_cache
  local container_name publisher_name store_volume
  local infra_sha git_remote nix_config delimiter changed commit_sha

  project_dir="$(cd -- "${GITHUB_WORKSPACE}/${INPUT_PROJECT_DIR:-.}" && pwd)"
  run_tag="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  state="${RUNNER_TEMP}/nix-ci-${run_tag}"
  build_tmp="${RUNNER_TEMP}/nix-build-${run_tag}"
  oranc_cache="${RUNNER_TEMP}/nix-ci-oranc-cache"
  container_name="nix-ci-${run_tag}"
  publisher_name="nix-ci-publisher-${run_tag}"
  store_volume="nix-ci-store-${run_tag}"
  infra_sha="$(git -C "$INFRA_DIR" rev-parse HEAD 2>/dev/null || true)"
  git_remote="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}.git"

  mkdir -p "$state" "$build_tmp" "$oranc_cache"
  cat > "$state/nix-base.conf" <<'CONFIG'
experimental-features = nix-command flakes
sandbox = false
accept-flake-config = false
system-features = nixos-test benchmark big-parallel kvm
max-jobs = 1
cores = 0
fallback = true
max-substitution-jobs = 4
http-connections = 8
substituters = https://cache.nixos.org https://nix-community.cachix.org https://cache.numtide.com
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=
require-sigs = true
CONFIG
  cp "$state/nix-base.conf" "$state/nix.conf"

  cat > "$state/gitconfig" <<'GITCONFIG'
[safe]
  directory = /workspace
  directory = /infra
  directory = *
GITCONFIG

  nix_config="$(printf 'experimental-features = nix-command flakes\naccess-tokens = github.com=%s\n' "$GITHUB_TOKEN")"
  export NIX_IMAGE="$NIX_DEFAULT_IMAGE"
  export NIX_CI_STATE="$state"
  export NIX_USER_CONF_FILES=/ci/nix.conf
  export NIX_CONFIG="$nix_config"

  changed=true
  if [[ "$update_mode" == true ]]; then
    local update_state host_uid host_gid
    update_state="$state/update"
    rm -rf -- "$update_state"
    mkdir -p "$update_state"
    host_uid="$(id -u)"
    host_gid="$(id -g)"
    INPUT_SELECT="${INPUT_SELECT:-"{}"}" \
    HOST_UID="$host_uid" \
    HOST_GID="$host_gid" \
      bash "$INFRA_DIR/ci/container.sh" --rm -i \
        --volume "$project_dir:/workspace" \
        --volume "$INFRA_DIR:/infra:ro" \
        --volume "$state:/ci:ro" \
        --volume "$update_state:/candidate" \
        --env INPUT_SELECT \
        --env HOST_UID \
        --env HOST_GID \
        --env GITHUB_RUN_ID \
        --env GITHUB_RUN_ATTEMPT \
        -- bash -euo pipefail <<'BASH'
trap 'chown -R "$HOST_UID:$HOST_GID" /workspace /candidate' EXIT
nix run --no-update-lock-file /infra#ci -- update prepare \
  --update-locks \
  --project-dir /workspace \
  --select "$INPUT_SELECT" \
  --state /candidate
BASH
    if [[ -f "$update_state/update.json" ]]; then
      changed=true
      commit_sha="$(jq -r '.head' "$update_state/update.json")"
    else
      changed=false
      commit_sha="$(git -C "$project_dir" rev-parse HEAD)"
    fi
  else
    commit_sha="$(git -C "$project_dir" rev-parse HEAD)"
  fi

  delimiter="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    printf 'NIX_IMAGE=%s\n' "$NIX_DEFAULT_IMAGE"
    printf 'NIX_CI_STATE=%s\n' "$state"
    printf 'NIX_CI_BUILD_TMP=%s\n' "$build_tmp"
    printf 'NIX_CI_ORANC_CACHE=%s\n' "$oranc_cache"
    printf 'NIX_CI_CONTAINER=%s\n' "$container_name"
    printf 'NIX_CI_PUBLISHER=%s\n' "$publisher_name"
    printf 'NIX_CI_STORE_VOLUME=%s\n' "$store_volume"
    printf 'NIX_CI_INFRA_DIR=%s\n' "$INFRA_DIR"
    printf 'NIX_CI_PROJECT_DIR=%s\n' "$project_dir"
    printf 'NIX_CI_COMMIT_SHA=%s\n' "$commit_sha"
    printf 'NIX_CI_INFRA_SHA=%s\n' "$infra_sha"
    printf 'NIX_CI_GIT_REMOTE=%s\n' "$git_remote"
    printf 'NIX_USER_CONF_FILES=/ci/nix.conf\n'
    printf 'ORANC_CACHE_MAX_BYTES=536870912\n'
    printf 'NIX_CONFIG<<%s\n%s\n%s\n' "$delimiter" "$nix_config" "$delimiter"
  } >> "$GITHUB_ENV"

  {
    printf 'state-dir=%s\n' "$state"
    printf 'changed=%s\n' "$changed"
    printf 'commit-sha=%s\n' "$commit_sha"
  } >> "$GITHUB_OUTPUT"
}

cmd_prepare_host() {
  local container_pid oranc_root
  date -u +%FT%TZ > "$NIX_CI_STATE/started"
  df -h / /mnt || df -h /
  sudo rm -rf -- \
    /usr/local/lib/android \
    /usr/share/dotnet \
    /opt/ghc \
    /usr/local/.ghcup \
    /usr/share/swift \
    /usr/local/share/boost
  if [[ ! -f "$NIX_CI_STATE/swap" ]]; then
    sudo fallocate -l 8G "$NIX_CI_STATE/swap"
    sudo chmod 600 "$NIX_CI_STATE/swap"
    sudo mkswap "$NIX_CI_STATE/swap"
    sudo swapon "$NIX_CI_STATE/swap"
  fi
  free -h
  sudo modprobe kvm
  test -c /dev/kvm
  sudo chmod 666 /dev/kvm

  docker volume create "$NIX_CI_STORE_VOLUME" >/dev/null
  bash "$NIX_CI_INFRA_DIR/ci/container.sh" --detach --name "$NIX_CI_CONTAINER" \
    --device /dev/kvm \
    --volume "$NIX_CI_STORE_VOLUME:/nix" \
    --volume "$NIX_CI_PROJECT_DIR:/workspace:ro" \
    --volume "$NIX_CI_INFRA_DIR:/infra:ro" \
    --volume "$NIX_CI_STATE:/ci" \
    --volume "$NIX_CI_BUILD_TMP:/build" \
    --volume "$NIX_CI_ORANC_CACHE:/oranc-cache" \
    --env TMPDIR=/build \
    -- sleep infinity

  container_pid="$(docker inspect --format '{{.State.Pid}}' "$NIX_CI_CONTAINER")"
  python3 "$NIX_CI_INFRA_DIR/ci" report monitor \
    --state "$NIX_CI_STATE" \
    --container-pid "$container_pid" \
    > "$NIX_CI_STATE/monitor.log" 2>&1 &

  docker exec "$NIX_CI_CONTAINER" bash -euo pipefail -c \
    'nix eval --no-update-lock-file --raw /infra#oranc.outPath > /ci/oranc-root'
  oranc_root="$(cat "$NIX_CI_STATE/oranc-root")"
  printf 'oranc-key=oranc-%s\n' "${oranc_root##*/}" >> "$GITHUB_OUTPUT"
}

cmd_bootstrap_oranc() {
  python3 "$NIX_CI_INFRA_DIR/ci" report run --state "$NIX_CI_STATE" --phase oranc -- \
    docker exec -i "$NIX_CI_CONTAINER" bash -euo pipefail <<'BASH'
expected_oranc="$(cat /ci/oranc-root)"
if compgen -G '/oranc-cache/*.narinfo' > /dev/null; then
  if nix copy --from file:///oranc-cache --no-check-sigs "$expected_oranc"; then
    echo 'Imported' > /ci/oranc-import
  else
    echo '::warning::Unable to import the oranc cache; continuing with normal Nix build.'
    echo 'Failed; using normal Nix build' > /ci/oranc-import
  fi
else
  echo 'No archive; using normal Nix build' > /ci/oranc-import
fi
oranc_root="$(nix build --no-update-lock-file --no-link --print-out-paths /infra#oranc)"
printf '%s\n' "$oranc_root" > /ci/oranc-root
printf '%s\n' "$oranc_root/bin/oranc" > /ci/oranc
nix path-info --closure-size "$oranc_root" > /ci/oranc-size
BASH
}

cmd_export_oranc() {
  local closure_bytes host_uid host_gid archive_bytes
  read -r _ closure_bytes < "$NIX_CI_STATE/oranc-size"
  if (( closure_bytes > ORANC_CACHE_MAX_BYTES )); then
    echo 'skip-reason=Runtime closure exceeds the size limit' >> "$GITHUB_OUTPUT"
    return 0
  fi
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  docker exec -i \
    --env HOST_UID="$host_uid" \
    --env HOST_GID="$host_gid" \
    "$NIX_CI_CONTAINER" bash -euo pipefail <<'BASH'
rm -rf /oranc-cache/*
nix copy --to "file:///oranc-cache?compression=none" "$(cat /ci/oranc-root)"
chown -R "$HOST_UID:$HOST_GID" /oranc-cache
BASH
  archive_bytes="$(du -sb "$NIX_CI_ORANC_CACHE" | cut -f1)"
  echo "archive-bytes=$archive_bytes" >> "$GITHUB_OUTPUT"
  if (( archive_bytes > ORANC_CACHE_MAX_BYTES )); then
    rm -rf -- "${NIX_CI_ORANC_CACHE:?}"/*
    echo 'skip-reason=Exported cache exceeds the size limit' >> "$GITHUB_OUTPUT"
    return 0
  fi
  echo 'ready=true' >> "$GITHUB_OUTPUT"
}

cmd_prepare_tools_and_manifest() {
  (
    umask 077
    printf 'machine 127.0.0.2\nlogin %s\npassword %s\n' \
      "$ORANC_USERNAME" "$ORANC_PASSWORD" > "$NIX_CI_STATE/oranc.netrc"
  )
  python3 "$NIX_CI_INFRA_DIR/ci" report run --state "$NIX_CI_STATE" --phase tools -- \
    docker exec -i \
      --env INPUT_SELECT="${INPUT_SELECT:-"{}"}" \
      "$NIX_CI_CONTAINER" bash -euo pipefail <<'BASH'
tools_root="$(nix build --no-update-lock-file --no-link --print-out-paths /infra#ci-tools)"
printf '%s\n' "$tools_root" > /ci/tools
printf '%s/bin/python3\n' "$tools_root" > /ci/python
export PATH="$tools_root/bin"
export PYTHONNOUSERSITE=1

RUST_LOG=oranc=info,oranc::registry=debug \
  "$(cat /ci/oranc)" server --listen 127.0.0.2:37515 < /dev/null 2>&1 | \
  python3 -u -c '
import datetime, sys
for line in sys.stdin:
    print(datetime.datetime.now(datetime.timezone.utc).isoformat() + " " + line.rstrip())
' > /ci/oranc.log 2>&1 &
proxy_pid=$!
for ((attempt=0; attempt<50; attempt++)); do
  if (exec 3<>/dev/tcp/127.0.0.2/37515) 2>/dev/null; then break; fi
  kill -0 "$proxy_pid"
  sleep 0.1
done

nix-ci evaluate --project-dir /workspace --select "$INPUT_SELECT" --state /ci
BASH
}

cmd_setup_cache() {
  local signing_key cache_mode publish_flag
  signing_key="$(printf '%s' "${ORANC_SIGNING_KEY:-}" | tr -d '[:space:]')"
  cache_mode="$(jq -r '.cache.mode // "none"' "$NIX_CI_STATE/manifest.json")"
  publish_flag=false

  if [[ -n "$signing_key" && "$cache_mode" != "none" ]]; then
    publish_flag=true
    ORANC_SIGNING_KEY="$signing_key" \
      bash "$NIX_CI_INFRA_DIR/ci/container.sh" --rm -i \
        --volume "$NIX_CI_STORE_VOLUME:/nix:ro" \
        --volume "$NIX_CI_PROJECT_DIR:/workspace:ro" \
        --volume "$NIX_CI_INFRA_DIR:/infra:ro" \
        --volume "$NIX_CI_STATE:/ci:ro" \
        --env ORANC_USERNAME \
        --env ORANC_PASSWORD \
        --env ORANC_SIGNING_KEY \
        -- bash -euo pipefail <<'BASH'
export PATH="$(cat /ci/tools)/bin"
export PYTHONNOUSERSITE=1
expected="$(jq -r '.cache.publicKey' /ci/manifest.json)"
actual="$(printf '%s' "$ORANC_SIGNING_KEY" | nix key convert-secret-to-public)"
if [[ "$actual" != "$expected" ]]; then
  echo 'NIX_CACHE_SIGNING_KEY does not match the declared cache public key.' >&2
  exit 1
fi
repository="$(jq -r '.cache.repository' /ci/manifest.json)"
registry="$(jq -r '.cache.registry // "ghcr.io"' /ci/manifest.json)"
timeout 60 "$(cat /ci/oranc)" push --registry "$registry" --repository "$repository" --parallel 1 initialize --priority 41
BASH
  fi

  docker exec -i \
    --env PUBLISH_CACHE="$publish_flag" \
    "$NIX_CI_CONTAINER" bash -euo pipefail <<'BASH'
export PATH="$(cat /ci/tools)/bin"
export PYTHONNOUSERSITE=1
extra_args=()
if [[ "$PUBLISH_CACHE" == true ]]; then
  extra_args+=(--publish)
fi
nix-ci cache configure-client --state /ci "${extra_args[@]}"
BASH

  printf 'publish=%s\n' "$publish_flag" >> "$GITHUB_OUTPUT"
}

cmd_run_builds() {
  local signing_key cache_mode publish_flag
  signing_key="$(printf '%s' "${ORANC_SIGNING_KEY:-}" | tr -d '[:space:]')"
  cache_mode="$(jq -r '.cache.mode // "none"' "$NIX_CI_STATE/manifest.json")"
  publish_flag=false

  if [[ -n "$signing_key" && "$cache_mode" == "incremental" ]]; then
    publish_flag=true
    ORANC_SIGNING_KEY="$signing_key" \
      bash "$NIX_CI_INFRA_DIR/ci/container.sh" --detach --name "$NIX_CI_PUBLISHER" \
        --network "container:$NIX_CI_CONTAINER" \
        --cpu-shares=256 \
        --memory=1536m --memory-swap=1536m \
        --volume "$NIX_CI_STORE_VOLUME:/nix" \
        --volume "$NIX_CI_PROJECT_DIR:/workspace:ro" \
        --volume "$NIX_CI_INFRA_DIR:/infra:ro" \
        --volume "$NIX_CI_STATE:/ci" \
        --env ORANC_USERNAME \
        --env ORANC_PASSWORD \
        --env ORANC_SIGNING_KEY \
        -- sleep infinity
    docker exec "$NIX_CI_PUBLISHER" bash -euo pipefail -c \
      'export PATH="$(cat /ci/tools)/bin" PYTHONNOUSERSITE=1; nix-ci cache start --project-dir /workspace --state /ci'
  fi

  docker exec -i \
    --env PUBLISH_CACHE="$publish_flag" \
    "$NIX_CI_CONTAINER" bash -euo pipefail <<'BASH'
export PATH="$(cat /ci/tools)/bin"
export PYTHONNOUSERSITE=1
extra_args=(--build-tmp /build --github-actions)
if [[ "$PUBLISH_CACHE" == true ]]; then
  extra_args+=(--publish)
fi
nix-ci run-groups --state /ci "${extra_args[@]}"
BASH
}

cmd_exec_hook() {
  if [[ -z "${HOOK_COMMAND:-}" ]]; then
    return 0
  fi
  rm -f -- "$NIX_CI_STATE/hook-summary.md"
  printf '%s\n' "$HOOK_COMMAND" | docker exec -i \
    --env GITHUB_ACTOR \
    --env GITHUB_TOKEN \
    --env NIX_CI_COMMIT_SHA \
    --env NIX_CI_INFRA_SHA \
    --env NIX_CI_GIT_REMOTE \
    --env GITHUB_STEP_SUMMARY=/ci/hook-summary.md \
    "$NIX_CI_CONTAINER" \
    bash -euo pipefail -c 'export PATH="$(cat /ci/tools)/bin:$PATH" PYTHONNOUSERSITE=1; exec bash -euo pipefail -s'
  if [[ -f "$NIX_CI_STATE/hook-summary.md" ]]; then
    cat "$NIX_CI_STATE/hook-summary.md" >> "$GITHUB_STEP_SUMMARY"
    rm -f -- "$NIX_CI_STATE/hook-summary.md"
  fi
}

cmd_merge_candidate() {
  local host_uid host_gid
  local -a store_args=()
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  rm -f -- "$NIX_CI_STATE/merge-github-output" "$NIX_CI_STATE/merge-step-summary.md"
  if docker volume inspect "$NIX_CI_STORE_VOLUME" >/dev/null 2>&1; then
    store_args+=(--volume "$NIX_CI_STORE_VOLUME:/nix:ro")
  fi
  HOST_UID="$host_uid" \
  HOST_GID="$host_gid" \
    bash "$NIX_CI_INFRA_DIR/ci/container.sh" --rm -i \
      "${store_args[@]}" \
      --volume "$NIX_CI_PROJECT_DIR:/workspace" \
      --volume "$NIX_CI_INFRA_DIR:/infra:ro" \
      --volume "$NIX_CI_STATE:/ci" \
      --env GH_TOKEN \
      --env GITHUB_REPOSITORY \
      --env GITHUB_SERVER_URL \
      --env GITHUB_RUN_ID \
      --env GITHUB_OUTPUT=/ci/merge-github-output \
      --env GITHUB_STEP_SUMMARY=/ci/merge-step-summary.md \
      --env HOST_UID \
      --env HOST_GID \
      -- bash -euo pipefail <<'BASH'
trap 'chown -R "$HOST_UID:$HOST_GID" /workspace /ci/update; chown "$HOST_UID:$HOST_GID" /ci/merge-github-output /ci/merge-step-summary.md 2>/dev/null || true' EXIT
if [[ -f /ci/tools && -x "$(cat /ci/tools)/bin/nix-ci" ]]; then
  "$(cat /ci/tools)/bin/nix-ci" update merge --project-dir /workspace --state /ci/update
else
  nix run --no-update-lock-file /infra#ci -- update merge --project-dir /workspace --state /ci/update
fi
BASH
  if [[ -f "$NIX_CI_STATE/merge-github-output" ]]; then
    cat "$NIX_CI_STATE/merge-github-output" >> "$GITHUB_OUTPUT"
  fi
  if [[ -f "$NIX_CI_STATE/merge-step-summary.md" ]]; then
    cat "$NIX_CI_STATE/merge-step-summary.md" >> "$GITHUB_STEP_SUMMARY"
  fi
}

cmd_teardown() {
  local state="${NIX_CI_STATE:-}"
  local container_pid
  if [[ -z "$state" || ! -d "$state" ]]; then
    return 0
  fi
  if [[ -n "${NIX_CI_PUBLISHER:-}" ]] && docker inspect "$NIX_CI_PUBLISHER" >/dev/null 2>&1; then
    docker exec "$NIX_CI_PUBLISHER" bash -euo pipefail -c \
      'export PATH="$(cat /ci/tools)/bin" PYTHONNOUSERSITE=1; nix-ci cache stop --state /ci' || true
    docker rm -f "$NIX_CI_PUBLISHER" >/dev/null 2>&1 || true
  fi
  rm -f -- "$state/oranc.netrc"
  touch "$state/monitor.stop"
  if [[ -n "${NIX_CI_CONTAINER:-}" ]] && container_pid="$(docker inspect --format '{{.State.Pid}}' "$NIX_CI_CONTAINER" 2>/dev/null)"; then
    python3 "$NIX_CI_INFRA_DIR/ci" report sample --state "$state" --container-pid "$container_pid" || true
    docker inspect --format '{{json .State}}' "$NIX_CI_CONTAINER" || true
  fi
  if [[ -f "$state/started" ]]; then
    sudo journalctl -k --since "$(cat "$state/started")" --utc --no-pager -o short-iso \
      --grep='(?i)out of memory|killed process|oom' 2>&1 | tee "$state/oom-kernel.log" > /dev/null || true
    sudo journalctl -u systemd-oomd --since "$(cat "$state/started")" --utc --no-pager -o short-iso \
      2>&1 | tee "$state/oom-userspace.log" > /dev/null || true
  fi
  python3 "$NIX_CI_INFRA_DIR/ci" report summary --state "$state" | tee -a "$GITHUB_STEP_SUMMARY"
  if [[ -n "${NIX_CI_CONTAINER:-}" ]]; then
    docker rm -f "$NIX_CI_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "${NIX_CI_STORE_VOLUME:-}" ]]; then
    docker volume rm -f "$NIX_CI_STORE_VOLUME" >/dev/null 2>&1 || true
  fi
}

subcommand="${1:-}"
shift || true
case "$subcommand" in
  init) cmd_init "$@" ;;
  prepare-host) cmd_prepare_host "$@" ;;
  bootstrap-oranc) cmd_bootstrap_oranc "$@" ;;
  export-oranc) cmd_export_oranc "$@" ;;
  prepare-tools-and-manifest) cmd_prepare_tools_and_manifest "$@" ;;
  setup-cache) cmd_setup_cache "$@" ;;
  run-builds) cmd_run_builds "$@" ;;
  exec-hook) cmd_exec_hook "$@" ;;
  merge-candidate) cmd_merge_candidate "$@" ;;
  teardown) cmd_teardown "$@" ;;
  *)
    printf 'Unknown runner.sh subcommand: %s\n' "$subcommand" >&2
    exit 2
    ;;
esac
