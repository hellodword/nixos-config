#! /usr/bin/env bash

trap "echo 'interrupted'; exit 1" SIGINT

images=()

if [ $# -eq 0 ]; then
  images=( $(docker images --format '{{.ID}}' | \
xargs docker inspect --format '{{json .}}' | \
jq -r 'select(.RepoDigests | length > 0) | .RepoTags[]' | \
sort -u) )
else
  images=( $(docker images --format '{{.ID}}' | \
xargs docker inspect --format '{{json .}}' | \
jq -r 'select(.RepoDigests | length > 0) | .RepoTags[]' | \
sort -u | $@) )
fi

printf '%s\n' "${images[@]}"
printf '\nupgrading %d images\n\n' "${#images[@]}"

for i in "${!images[@]}"; do
    image="${images[$i]}"
    echo "### docker pull $image"

    while ! docker pull "$image";
    do
      sleep 2s
    done

    echo
done
