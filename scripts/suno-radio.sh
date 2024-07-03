#! /usr/bin/env bash

set -e

_HOST="$(curl -s https://raw.githubusercontent.com/hellodword/suno-radio/master/README.md | grep -oP 'https://[a-z\d\-]+.trycloudflare.com' | head -1)"

cleanup() {
    if [[ -n $TARGET_PID ]]; then
        kill "$TARGET_PID" || true
        wait "$TARGET_PID" || true
        TARGET_PID=""
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

if [[ $# -eq 0 || "$1" == "status" ]]; then
    curl -s "$_HOST/v1/playlist" | jq
else
    set +e

    while true
    do
        curl -s "$_HOST/v1/playlist/$1" | ffplay -hide_banner -autoexit -nodisp - &
        TARGET_PID=$!
        wait "$TARGET_PID"
        sleep 3s
    done
fi
