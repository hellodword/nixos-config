#! /usr/bin/env bash

# https://www.scaleway.com/en/developers/api/instance/#availability-zones
zones=("fr-par-1" "fr-par-2" "fr-par-3" "nl-ams-1" "nl-ams-2" "pl-waw-1" "pl-waw-2")

for i in ${!zones[@]}; do
  zone="${zones[$i]}"
  sleep 1s
  echo "$zone"
  curl -s "https://api.scaleway.com/instance/v1/zones/"$zone"/products/servers/availability?per_page=100" | \
    jq -r '.servers."STARDUST1-S".availability'
done
