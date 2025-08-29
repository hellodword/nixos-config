#! /usr/bin/env bash

set -e

rules=()
DNS=""

if [ -n "$NCN" ]; then
  rules=(
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-geolocation-!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-alibaba@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-alibabacloud@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-aliyun@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-bilibili@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-bytedance@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-huawei@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-huaweicloud@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-jd@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-qcloud@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tencent-games@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tencent@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tiktok@!cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-xiaomi@!cn.json"
  )
  DNS="127.0.0.1#55553"
else
  rules=(
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-geolocation-cn.json"
      "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-google-trust-services%40cn.json"
  )
  DNS="127.0.0.1#55554"
fi

for i in ${!rules[@]}; do
  rule="${rules[$i]}"
  response="$(curl -fsSL "$rule")"
  echo "$response" | jq -e 'has("rules")' >/dev/null 2>&1
  echo "$response" | jq -r '.rules[] | .domain[]' | sed -E 's@^@server=\/:^@g' | sed -E "s@\$@$:\/$DNS@g" || true
  echo "$response" | jq -r '.rules[] | .domain_suffix[]' | sed -E 's@^\.?@server=\/@g' | sed -E "s@\$@\/$DNS@g" || true
  echo "$response" | jq -r '.rules[] | .domain_regex[]' | sed -E 's@^@server=\/:@g' | sed -E "s@\$@:\/$DNS@g" || true
done

# ./scripts/generate-dnsmasq.sh | sort -u | sudo tee /usr/local/etc/dnsmasq/dnsmasq.d/99-cn.conf
