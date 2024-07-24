set -e
set -x

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

    ips=( $(echo "$_DATA" | jq -r ".info.$_TYPE_UPPER[] | .ip") )
    if [ "${#ips[@]}" = "5" ]; then
        for i in ${!ips[@]}; do
                ip="${ips[$i]}"
                cat <<< $( jq "(.outbounds[] | select(.tag | startswith(\"proxy:us:cf:yes-$_TYPE_LOWER-$_FAMILY-$i\"))).server = \"$ip\"" "$CONFIG_FILE" )      > "$CONFIG_FILE"
                cat <<< $( jq "(.outbounds[] | select(.tag | startswith(\"hideme:us:cf:yes-$_TYPE_LOWER-$_FAMILY-$i\"))).server = \"$ip\"" "$CONFIG_FILE" )      > "$CONFIG_FILE"
        done
    fi
}

ORIGIN="$(jq -r '.outbounds[] | select(.tag | startswith("proxy:us:cf:yes-")).server' /usr/local/etc/sing-box/outbounds.json | sort)"

RESOLVE="$(kdig +short api.hostmonit.com @1.12.12.12 +https | head -1 || kdig +short api.hostmonit.com @223.5.5.5 +https | head -1)"

[ -n "$RESOLVE" ]

_DATA="$(curl --resolve "api.hostmonit.com:443:$RESOLVE" --interface "$INTERFACE" -X POST -fsSL https://api.hostmonit.com/get_optimization_ip --json '{"key":"o1zrmHAF", "type":"v4"}')"
handle_2 "v4" "cm" "$_DATA"

_DATA="$(curl --resolve "api.hostmonit.com:443:$RESOLVE" --interface "$INTERFACE" -X POST -fsSL https://api.hostmonit.com/get_optimization_ip --json '{"key":"o1zrmHAF", "type":"v6"}')"
handle_2 "v6" "cm" "$_DATA"

NEW="$(jq -r '.outbounds[] | select(.tag | startswith("proxy:us:cf:yes-")).server' /usr/local/etc/sing-box/outbounds.json | sort)"

if [ "$ORIGIN" != "$NEW" ]; then
    systemctl restart sing-box
fi
