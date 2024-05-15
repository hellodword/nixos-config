#! /usr/bin/env bash

set -e

_HOST="https://gas-observe-ky-mention.trycloudflare.com"

if [[ $# -eq 0 || "$1" == "status" ]]; then
    curl -s "$_HOST/v1/playlist" | jq
else
    curl -s "$_HOST/v1/playlist/$1" | ffplay -hide_banner -autoexit -nodisp -
fi
