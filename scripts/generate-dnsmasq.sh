#! /usr/bin/env bash

set -e

sing_box_rules=(
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-geolocation-cn.json"
    "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-google-trust-services%40cn.json"
)
DNS="127.0.0.1#55554"

for i in ${!sing_box_rules[@]}; do
  sing_box_rule="${sing_box_rules[$i]}"
  response="$(curl -fsSL "$sing_box_rule")"
  echo "$response" | jq -e 'has("rules")' >/dev/null 2>&1
  echo "$response" | jq -r '.rules[] | .domain[]' | sed -E 's@^@server=\/:^@g' | sed -E "s@\$@$:\/$DNS@g" || true
  echo "$response" | jq -r '.rules[] | .domain_suffix[]' | sed -E 's@^\.?@server=\/@g' | sed -E "s@\$@\/$DNS@g" || true
  echo "$response" | jq -r '.rules[] | .domain_regex[]' | sed -E 's@^@server=\/:@g' | sed -E "s@\$@:\/$DNS@g" || true
done

# ./scripts/generate-dnsmasq.sh | sort -u | sudo tee /usr/local/etc/dnsmasq/dnsmasq.d/cn.conf
