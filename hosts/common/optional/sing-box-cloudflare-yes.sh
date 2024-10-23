set -e
set -x

# https://www.v2ex.com/t/1016999
# https://monitor.gacjie.cn/page/cloudflare/ipv6.html

INTERFACE="$1"
if [ -z "$INTERFACE" ]; then
    INTERFACE="$(ip route | grep '^default' | grep -oP '(?<=dev )[^ \n]+' | head -1)"
fi
[ -n "$INTERFACE" ]
ip a show "$INTERFACE"

CONFIG_FILE="/usr/local/etc/sing-box/outbounds.json"

function handle_2() {
    _FAMILY="$1"
    _TYPE="$2"
    _DATA="$3"

    _TYPE_LOWER="$(echo "$_TYPE" | awk '{print tolower($0)}')"
    _TYPE_UPPER="$(echo "$_TYPE" | awk '{print toupper($0)}')"

    ips=( $(echo "$_DATA" | jq -r ".info[] | select( .line == \"$_TYPE_UPPER\") | .ip") )

    if [ "${#ips[@]}" = "5" ]; then
        for i in ${!ips[@]}; do
                ip="${ips[$i]}"
                cat <<< $( jq "(.outbounds[] | select(.tag | startswith(\"proxy:us:cf:yes-$_TYPE_LOWER-$_FAMILY-$i\"))).server = \"$ip\"" "$CONFIG_FILE" )      > "$CONFIG_FILE"
                cat <<< $( jq "(.outbounds[] | select(.tag | startswith(\"hideme:us:cf:yes-$_TYPE_LOWER-$_FAMILY-$i\"))).server = \"$ip\"" "$CONFIG_FILE" )      > "$CONFIG_FILE"
        done
    fi
}

ORIGIN="$(jq -r '.outbounds[] | select(.tag | startswith("proxy:us:cf:yes-")).server' "$CONFIG_FILE" | sort)"

servers=( "1.12.12.12" "120.53.53.53" "223.5.5.5" "223.6.6.6" )
for i in ${!servers[@]}; do
    RESOLVE="$(kdig +short api.hostmonit.com "@${servers[$i]}" +https | head -1 || true)"
    if [ -n "$RESOLVE" ]; then
        break
    fi
    sleep 3s
done
[ -n "$RESOLVE" ]

_DATA="$(curl --resolve "api.hostmonit.com:443:$RESOLVE" --interface "$INTERFACE" -X POST -fsSL https://api.hostmonit.com/get_optimization_ip -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; rv:129.0) Gecko/20100101 Firefox/129.0' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: gzip, deflate, br, zstd' -H 'Content-Type: application/json' -H 'Origin: https://stock.hostmonit.com' -H 'DNT: 1' -H 'Connection: keep-alive' -H 'Referer: https://stock.hostmonit.com/' -H 'Sec-Fetch-Dest: empty' -H 'Sec-Fetch-Mode: cors' -H 'Sec-Fetch-Site: same-site' -H 'Priority: u=0' -H 'TE: trailers' --json '{"key":"iDetkOys", "type":"v4"}')"
handle_2 "v4" "cm" "$_DATA"
handle_2 "v4" "cu" "$_DATA"
handle_2 "v4" "ct" "$_DATA"

_DATA="$(curl --resolve "api.hostmonit.com:443:$RESOLVE" --interface "$INTERFACE" -X POST -fsSL https://api.hostmonit.com/get_optimization_ip -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; rv:129.0) Gecko/20100101 Firefox/129.0' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: gzip, deflate, br, zstd' -H 'Content-Type: application/json' -H 'Origin: https://stock.hostmonit.com' -H 'DNT: 1' -H 'Connection: keep-alive' -H 'Referer: https://stock.hostmonit.com/' -H 'Sec-Fetch-Dest: empty' -H 'Sec-Fetch-Mode: cors' -H 'Sec-Fetch-Site: same-site' -H 'Priority: u=0' -H 'TE: trailers' --json '{"key":"iDetkOys", "type":"v6"}')"
handle_2 "v6" "cm" "$_DATA"
handle_2 "v6" "cu" "$_DATA"
handle_2 "v6" "ct" "$_DATA"

NEW="$(jq -r '.outbounds[] | select(.tag | startswith("proxy:us:cf:yes-")).server' "$CONFIG_FILE" | sort)"

if [ "$ORIGIN" != "$NEW" ]; then
    systemctl restart sing-box
fi
