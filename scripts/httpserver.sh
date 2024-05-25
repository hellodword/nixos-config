#! /usr/bin/env bash

set -e

if [[ $# -eq 0 || "$1" == "" ]]; then
    httpserver_arg1="$(pwd)"
else
    httpserver_arg1="$(readlink -f "$1")"
fi

if [ -d "$httpserver_arg1" ]; then
    docker run --rm --runtime runsc --user "$(id -u)":"$(id -g)" -v "$httpserver_arg1":/w:ro -w /w -p 8000:8000 -it python python -m http.server
elif [ -f "$httpserver_arg1" ]; then
    docker run --rm --runtime runsc --user "$(id -u)":"$(id -g)" -v "$httpserver_arg1":/w/"$(basename "$httpserver_arg1")":ro -w /w -p 8000:8000 -it python python -m http.server
else
    echo "$httpserver_arg1"
    exit 1
fi
