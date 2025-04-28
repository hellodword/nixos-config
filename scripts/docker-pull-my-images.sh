#! /usr/bin/env bash

set -o pipefail

trap "echo 'interrupted'; exit 1" SIGINT

images=()

if [ $# -eq 0 ]; then
  images=(
    $(
      (
        # images pulled from remote
        docker images --format '{{.ID}}' | \
          xargs docker inspect --format '{{json .}}' | \
          jq -r 'select(.RepoDigests | length > 0) | .RepoTags[]';
        # pull ghcr images even they've been built locally
        docker images --format '{{.ID}}' | \
          xargs docker inspect --format '{{json .}}' | \
          jq '.RepoTags | map(select(startswith("ghcr.io/")))' | \
          jq -r '.[]'
      ) | \
      sort -u
    )
  )
else
  images=(
    $(
      (
        docker images --format '{{.ID}}' | \
          xargs docker inspect --format '{{json .}}' | \
          jq -r 'select(.RepoDigests | length > 0) | .RepoTags[]';
        docker images --format '{{.ID}}' | \
          xargs docker inspect --format '{{json .}}' | \
          jq '.RepoTags | map(select(startswith("ghcr.io/")))' | \
          jq -r '.[]'
      ) | \
      sort -u | $@
    )
  )
fi

printf '%s\n' "${images[@]}"
printf '\nupgrading %d images\n\n' "${#images[@]}"

for i in "${!images[@]}"; do
    image="${images[$i]}"
    echo "### docker pull $image"

    while true; do
        tmpfile=$(mktemp)
        set +e
        (docker pull "$image" 2>&1 | tee "$tmpfile")
        status=${PIPESTATUS[0]}
        set -e
        # Error response from daemon: pull access denied for hellodword/foo, repository does not exist or may require 'docker login': denied: requested access to the resource is denied
        # Error response from daemon: manifest for sickcodes/docker-osx:catalina not found: manifest unknown: manifest unknown
        # Error response from daemon: Head "https://ghcr.io/v2/hellodword/foo/manifests/latest": denied
        if [ "$status" -eq 0 ] || grep -q 'does not exist' "$tmpfile" || grep -q 'manifest unknown' "$tmpfile" || grep -q 'Head .\+/manifests/.\+: denied' "$tmpfile"; then
            echo "status=$status"
            rm -f "$tmpfile"
            break
        fi
        rm -f "$tmpfile"
        sleep 2s
    done

    echo
done
