#! /usr/bin/env bash

set -e

# https://coderadio.freecodecamp.org/
# https://stackoverflow.com/questions/11831214/how-to-run-ffplay-as-a-window-less-process/53295994#53295994
curl -s https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3 "$@" | ffplay -hide_banner -autoexit -nodisp -
