# DNS

- rdns
- mdns
- dns client
- dns server
- root server

## public servers (IP Only)

- https://dnscrypt.info/public-servers/
- https://public-dns.info/
- https://dns.iui.im/
- https://en.wikipedia.org/wiki/Public_recursive_name_server#Notable_public_DNS_service_operators
- https://dnschecker.org/public-dns/us
- https://meta.wikimedia.org/wiki/Wikimedia_DNS
- https://developers.cloudflare.com/1.1.1.1/faq/#does-1.1.1.1-send-edns-client-subnet-header
- https://www.quad9.net/support/faq/#edns
- https://docs.quad9.net/services/
- https://docs.quad9.net/services/#alternate-ports

```sh
#! /bin/bash

set -e
kdig="sudo docker run --rm --network host cznic/knot:latest kdig"
q='sudo docker run --rm --network host ghcr.io/natesales/q'

$kdig -V
$q -V
openssl version
set +e

connect_timeout="2s"

function handle_ip() {
    provider="$1"
    ip_raw="$2"
    ip_final="$ip_raw"
    if [[ "$ip_final" =~ .*:.* ]]; then
        ip_final="[$ip_final]"
    fi

    if [ "$(timeout "$connect_timeout" openssl s_client -connect $ip_final:443 -state -nbio 2>/dev/null | grep 'Verify return code: 0 (ok)' | wc -l)" -eq "0" ] && [ "$(timeout "$connect_timeout" openssl s_client -connect $ip_final:853 -state -nbio 2>/dev/null | grep 'Verify return code: 0 (ok)' | wc -l)" -eq "0" ]; then
        return
    fi

    if [ "$($kdig +short +tls @$ip_final github.com 2>/dev/null | wc -l)" -ne "0" ]; then
        dot="Y"
    else
        dot="N"
    fi

    if [ "$($kdig +short +https @$ip_final github.com 2>/dev/null | wc -l)" -ne "0" ]; then
        doh="Y"
    else
        doh="N"
    fi

    if [ "$($kdig +short +quic @$ip_final github.com 2>/dev/null | wc -l)" -ne "0" ]; then
        doq="Y"
    else
        doq="N"
    fi

    if [ "$($q --short --http3 A @https://$ip_final github.com 2>/dev/null | wc -l)" -ne "0" ]; then
        doh3="Y"
    else
        doh3="N"
    fi

    ecs_checker="https"
    if [ "$dot" == "Y" ]; then
        ecs_checker="tls"
    elif [ "$doq" == "Y" ]; then
        ecs_checker="quic"
    fi

    ecs="N"
    if [ "$($kdig +$ecs_checker @$ip_final github.com +subnet=1.1.1.0/24 2>/dev/null | grep 'CLIENT-SUBNET: 1.1.1.0/24' | wc -l)" -ne "0" ]; then
        if [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=140.82.112.3/24 +short 2>/dev/null | head -1)" =~ ^140.82.* ]] && \
           [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=20.27.177.113/24 +short 2>/dev/null | head -1)" =~ ^20.27.* ]] && \
           [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=140.82.112.3/24 +short 2>/dev/null | head -1)" =~ ^140.82.* ]] && \
           [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=20.27.177.113/24 +short 2>/dev/null | head -1)" =~ ^20.27.* ]] && \
           [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=140.82.112.3/24 +short 2>/dev/null | head -1)" =~ ^140.82.* ]] && \
           [[ "$($kdig +$ecs_checker @$ip_final github.com +subnet=20.27.177.113/24 +short 2>/dev/null | head -1)" =~ ^20.27.* ]]; then
            ecs="Y"
        fi
    fi

    if [ "$dot" == "Y" ] || [ "$doh" == "Y" ] || [ "$doq" == "Y" ] || [ "$doh3" == "Y" ]; then
        echo "| $provider | $ip_raw | $ecs | $dot | $doh | $doq | $doh3 |"
    fi
}

declare -A providers=(
    ["Cloudflare"]="cloudflare-dns.com; security.cloudflare-dns.com; dns64.cloudflare-dns.com; 2a10:50c0::ad1:ff; 2a10:50c0::ad2:ff; 2a10:50c0::1:ff; 2a10:50c0::2:ff"
    ["Google"]="dns.google; dns64.dns.google; 8888.google"
    ["Quard9"]="dns.quad9.net; dns10.quad9.net; dns11.quad9.net"
    ["OpenDNS"]="dns.opendns.com; sandbox.opendns.com"
    ["AdGuard"]="dns.adguard.com"
    ["NextDNS(dns0.eu)"]="dns0.eu"
    ["CleanBrowsing"]="security-filter-dns.cleanbrowsing.org; 185.228.168.9; 185.228.169.9; 2a0d:2a00:1::2; 2a0d:2a00:2::2"
    ["Mullvad"]="dns.mullvad.net; adblock.dns.mullvad.net; base.dns.mullvad.net; 194.242.2.2; 2a07:e340::2; 194.242.2.3; 2a07:e340::3; 194.242.2.4; 2a07:e340::4"
    ["Wikimedia"]="wikimedia-dns.org"
)

for provider in "${!providers[@]}"; do
    ips=()
    IFS='; ' read -r -a provider_entries <<< "${providers[$provider]}"
    for provider_entry in "${provider_entries[@]}"; do
        if [[ "$provider_entry" =~ ^[0-9\.]+$ ]] || [[ "$provider_entry" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
            ips+=("$provider_entry")
        else
            ips+=( $(timeout "$connect_timeout" openssl s_client -connect "$provider_entry:443" 2>/dev/null | openssl x509 -noout -text | grep -oP '(?<=IP Address:)[^\n ,]+') )

            cert_domains=( $(timeout "$connect_timeout" openssl s_client -connect "$provider_entry:443" 2>/dev/null | openssl x509 -noout -text | grep -oP '(?<=DNS:)[^\n ,]+') )
            for i in ${!cert_domains[@]}; do
                cert_domain="${cert_domains[$i]}"
                if [[ "$cert_domain" =~ ^[^\*] ]]; then
                    ips+=( $($kdig +tls @1.1.1.1 +short A "$cert_domain" 2>/dev/null) )
                    ips+=( $($kdig +tls @1.1.1.1 +short AAAA "$cert_domain" 2>/dev/null) )
                fi
            done
        fi
    done

    ips_uniq=($(echo "${ips[@]}" | tr ' ' '\n' | sort -u | awk '{print tolower($0)}' | tr '\n' ' '))

    for i in ${!ips_uniq[@]}; do
            ip="${ips_uniq[$i]}"
            if [[ "$ip" =~ ^[0-9\.]+$ ]] || [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
                handle_ip "$provider" "$ip"
            fi
    done
done
```

| provider         | server                                 | ECS | DoT | DoH | DoQ | DoH3 |
| ---------------- | -------------------------------------- | --- | --- | --- | --- | ---- |
| Mullvad          | 146.70.192.62                          | N   | Y   | Y   | N   | N    |
| Mullvad          | 194.242.2.2                            | N   | Y   | Y   | N   | N    |
| Mullvad          | 194.242.2.3                            | N   | Y   | Y   | N   | N    |
| Mullvad          | 194.242.2.4                            | N   | Y   | Y   | N   | N    |
| Mullvad          | 194.242.2.5                            | N   | Y   | Y   | N   | N    |
| Mullvad          | 194.242.2.9                            | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a07:e340::2                           | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a07:e340::3                           | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a07:e340::4                           | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a07:e340::5                           | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a07:e340::9                           | N   | Y   | Y   | N   | N    |
| Mullvad          | 2a0d:5600:d:61::2                      | N   | Y   | Y   | N   | N    |
| OpenDNS          | 146.112.41.2                           | N   | N   | Y   | N   | N    |
| OpenDNS          | 146.112.41.3                           | N   | N   | Y   | N   | N    |
| OpenDNS          | 146.112.41.4                           | N   | N   | Y   | N   | N    |
| OpenDNS          | 146.112.41.5                           | N   | N   | Y   | N   | N    |
| OpenDNS          | 204.194.232.200                        | N   | Y   | Y   | N   | N    |
| OpenDNS          | 204.194.234.200                        | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.220.123                         | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.220.2                           | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.220.220                         | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.222.123                         | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.222.2                           | N   | Y   | Y   | N   | N    |
| OpenDNS          | 208.67.222.222                         | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:0:ccc:0:0:0:0:2                   | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:0:ccd:0:0:0:0:2                   | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:0:ccc::2                          | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:0:ccd::2                          | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:35:0:0:0:0:123                | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:35:0:0:0:0:35                 | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:35::123                       | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:35::35                        | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:53:0:0:0:0:123                | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:53:0:0:0:0:53                 | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:53::123                       | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:53::53                        | N   | Y   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc:0:0:0:0:2                  | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc:0:0:0:0:3                  | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc:0:0:0:0:4                  | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc:0:0:0:0:5                  | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc::2                         | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc::3                         | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc::4                         | N   | N   | Y   | N   | N    |
| OpenDNS          | 2620:119:fc::5                         | N   | N   | Y   | N   | N    |
| NextDNS(dns0.eu) | 185.253.5.0                            | N   | Y   | Y   | Y   | Y    |
| NextDNS(dns0.eu) | 193.110.81.0                           | N   | Y   | Y   | Y   | N    |
| NextDNS(dns0.eu) | 2a01:4f9:c012:6f37::1                  | N   | N   | Y   | Y   | N    |
| NextDNS(dns0.eu) | 2a04:3540:1000:310:90ba:edff:fe55:2f7c | N   | N   | Y   | Y   | N    |
| NextDNS(dns0.eu) | 65.108.52.121                          | N   | N   | Y   | Y   | N    |
| NextDNS(dns0.eu) | 94.237.112.248                         | N   | N   | Y   | Y   | N    |
| Quard9           | 149.112.112.10                         | N   | Y   | Y   | N   | N    |
| Quard9           | 149.112.112.11                         | Y   | Y   | Y   | N   | N    |
| Quard9           | 149.112.112.112                        | N   | Y   | Y   | N   | N    |
| Quard9           | 149.112.112.12                         | Y   | Y   | Y   | N   | N    |
| Quard9           | 149.112.112.13                         | N   | Y   | Y   | N   | N    |
| Quard9           | 149.112.112.9                          | N   | Y   | Y   | N   | N    |
| Quard9           | 216.21.3.77                            | N   | N   | Y   | N   | N    |
| Quard9           | 2620:0:871:9000::77                    | N   | N   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:10                   | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:11                   | Y   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:12                   | Y   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:13                   | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:9                    | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:0:fe                   | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:fe:10                  | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:fe:11                  | Y   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:fe:12                  | Y   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:fe:13                  | N   | Y   | Y   | N   | N    |
| Quard9           | 2620:fe:0:0:0:0:fe:9                   | N   | Y   | Y   | N   | N    |
| Quard9           | 9.9.9.10                               | N   | Y   | Y   | N   | N    |
| Quard9           | 9.9.9.11                               | Y   | Y   | Y   | N   | N    |
| Quard9           | 9.9.9.12                               | Y   | Y   | Y   | N   | N    |
| Quard9           | 9.9.9.13                               | N   | Y   | Y   | N   | N    |
| Quard9           | 9.9.9.9                                | N   | Y   | Y   | N   | N    |
| Cloudflare       | 1.0.0.1                                | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 1.0.0.2                                | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 1.1.1.1                                | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 1.1.1.2                                | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 104.16.248.249                         | N   | N   | Y   | N   | N    |
| Cloudflare       | 104.16.249.249                         | N   | N   | Y   | N   | N    |
| Cloudflare       | 162.159.36.1                           | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 162.159.46.1                           | N   | Y   | Y   | N   | Y    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1001            | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1002            | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1111            | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1112            | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:64              | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700:0:0:0:0:6400            | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700::1001                   | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700::1002                   | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700::1111                   | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700:4700::1112                   | N   | Y   | Y   | N   | N    |
| Cloudflare       | 2606:4700::6810:f8f9                   | N   | N   | Y   | N   | N    |
| Cloudflare       | 2606:4700::6810:f9f9                   | N   | N   | Y   | N   | N    |
| Cloudflare       | 2a10:50c0::1:ff                        | N   | Y   | Y   | Y   | N    |
| Cloudflare       | 2a10:50c0::2:ff                        | N   | Y   | Y   | Y   | N    |
| Cloudflare       | 2a10:50c0::ad1:ff                      | N   | Y   | Y   | Y   | N    |
| Cloudflare       | 2a10:50c0::ad2:ff                      | N   | Y   | Y   | Y   | N    |
| Wikimedia        | 185.71.138.138                         | N   | Y   | Y   | N   | N    |
| Wikimedia        | 2001:67c:930::1                        | N   | Y   | Y   | N   | N    |
| AdGuard          | 2a10:50c0::1:ff                        | N   | Y   | Y   | Y   | N    |
| AdGuard          | 2a10:50c0::2:ff                        | N   | Y   | Y   | Y   | N    |
| AdGuard          | 2a10:50c0::ad1:ff                      | N   | Y   | Y   | Y   | N    |
| AdGuard          | 2a10:50c0::ad2:ff                      | N   | Y   | Y   | Y   | N    |
| AdGuard          | 2a10:50c0::bad1:ff                     | N   | Y   | Y   | Y   | N    |
| AdGuard          | 2a10:50c0::bad2:ff                     | N   | Y   | Y   | Y   | N    |
| AdGuard          | 94.140.14.14                           | N   | Y   | Y   | Y   | Y    |
| AdGuard          | 94.140.14.140                          | N   | Y   | Y   | Y   | Y    |
| AdGuard          | 94.140.14.141                          | N   | Y   | Y   | Y   | Y    |
| AdGuard          | 94.140.14.15                           | N   | Y   | Y   | Y   | Y    |
| AdGuard          | 94.140.15.15                           | N   | Y   | Y   | Y   | Y    |
| AdGuard          | 94.140.15.16                           | N   | Y   | Y   | Y   | Y    |
| Google           | 2001:4860:4860:0:0:0:0:64              | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860:0:0:0:0:6464            | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860:0:0:0:0:8844            | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860:0:0:0:0:8888            | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860::64                     | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860::6464                   | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860::8844                   | Y   | Y   | Y   | N   | Y    |
| Google           | 2001:4860:4860::8888                   | Y   | Y   | Y   | N   | Y    |
| Google           | 8.8.4.4                                | Y   | Y   | Y   | N   | Y    |
| Google           | 8.8.8.8                                | Y   | Y   | Y   | N   | Y    |
| CleanBrowsing    | 185.228.168.9                          | N   | Y   | Y   | N   | N    |
| CleanBrowsing    | 185.228.169.9                          | N   | Y   | Y   | N   | N    |
| CleanBrowsing    | 2a0d:2a00:1::2                         | N   | Y   | N   | N   | N    |
| CleanBrowsing    | 2a0d:2a00:2::2                         | N   | Y   | N   | N   | N    |
