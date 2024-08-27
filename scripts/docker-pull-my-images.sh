#! /usr/bin/env bash

trap "echo 'interrupted'; exit 1" SIGINT

images=( $(docker images | tail -n +2 | grep -v '<none>' | awk '{print $1 ":" $2}' | xargs docker inspect | jq '.[] | select(.RepoDigests | length > 0)' | jq -r '.RepoTags[]' | sort -u) )

for i in "${!images[@]}"; do
    image="${images[$i]}"
    echo "### docker pull $image"

    while ! docker pull "$image";
    do
      sleep 2s
    done

    echo
done
