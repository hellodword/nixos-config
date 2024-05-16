#! /usr/bin/env bash

set -e

# https://coderadio.freecodecamp.org/
# https://stackoverflow.com/questions/11831214/how-to-run-ffplay-as-a-window-less-process/53295994#53295994

cleanup() {
    if [[ -n $TARGET_PID ]]; then
        kill "$TARGET_PID"
        wait "$TARGET_PID" || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

set +e

while true
do
    curl -s https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3 "$@" | ffplay -hide_banner -autoexit -nodisp - &
    TARGET_PID=$!
    wait "$TARGET_PID"
    sleep 3s
done
