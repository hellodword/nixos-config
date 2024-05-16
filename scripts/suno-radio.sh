#! /usr/bin/env bash

set -e

_HOST="https://looked-livecam-formula-novel.trycloudflare.com"

cleanup() {
    if [[ -n $TARGET_PID ]]; then
        kill "$TARGET_PID"
        wait "$TARGET_PID" || true
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
