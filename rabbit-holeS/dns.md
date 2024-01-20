# DNS

- rdns
- mdns
- dns client
- dns server
- root server

## public servers (IP Only)

- https://public-dns.info/
- https://dns.iui.im/

```sh
openssl s_client -connect 9.9.9.9:443 2>/dev/null | \
openssl x509 -noout -text | \
grep -oP '(?<=IP Address:)[^\n ,]+' | \
xargs -I {} bash -c '(kdig +short +tls github.com @{} >/dev/null 2>&1 || kdig +short +tls github.com @[{}] >/dev/null 2>&1) && echo {}'
```

- https://developers.cloudflare.com/1.1.1.1/faq/#does-1.1.1.1-send-edns-client-subnet-header
- https://www.quad9.net/support/faq/#edns

| provider         | server                      | ECS | DoT | DoH | DoQ | DoH3 |
| ---------------- | --------------------------- | --- | --- | --- | --- | ---- |
| Cloudflare       | 1.1.1.1                     | N   | Y   |     |     |      |
| Cloudflare       | 1.0.0.1                     | N   | Y   |     |     |      |
| Cloudflare       | 162.159.36.1                | N   | Y   |     |     |      |
| Cloudflare       | 162.159.46.1                | N   | Y   |     |     |      |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1001 | N   | Y   |     |     |      |
| Cloudflare       | 2606:4700:4700:0:0:0:0:1111 | N   | Y   |     |     |      |
| Cloudflare       | 2606:4700:4700:0:0:0:0:64   | N   | Y   |     |     |      |
| Cloudflare       | 2606:4700:4700:0:0:0:0:6400 | N   | Y   |     |     |      |
| Google           | 8.8.8.8                     | Y   | Y   |     |     |      |
| Google           | 8.8.4.4                     | Y   | Y   |     |     |      |
| Google           | 2001:4860:4860:0:0:0:0:8888 | Y   | Y   |     |     |      |
| Google           | 2001:4860:4860:0:0:0:0:8844 | Y   | Y   |     |     |      |
| Google           | 2001:4860:4860:0:0:0:0:6464 | Y   | Y   |     |     |      |
| Google           | 2001:4860:4860:0:0:0:0:64   | Y   | Y   |     |     |      |
| Quard9           | 9.9.9.11                    | Y   | Y   |     |     |      |
| Quard9           | 149.112.112.11              | Y   | Y   |     |     |      |
| Quard9           | 2620:fe::11                 | Y   | Y   |     |     |      |
| Quard9           | 2620:fe::fe:11              | Y   | Y   |     |     |      |
| Quard9           | 9.9.9.9                     |     | Y   |     |     |      |
| Quard9           | 9.9.9.10                    |     | Y   |     |     |      |
| Quard9           | 9.9.9.12                    |     | Y   |     |     |      |
| Quard9           | 9.9.9.13                    |     | Y   |     |     |      |
| Quard9           | 149.112.112.9               |     | Y   |     |     |      |
| Quard9           | 149.112.112.10              |     | Y   |     |     |      |
| Quard9           | 149.112.112.12              |     | Y   |     |     |      |
| Quard9           | 149.112.112.13              |     | Y   |     |     |      |
| Quard9           | 149.112.112.112             |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:0:9         |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:0:10        |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:0:12        |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:0:13        |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:0:FE        |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:FE:9        |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:FE:10       |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:FE:12       |     | Y   |     |     |      |
| Quard9           | 2620:FE:0:0:0:0:FE:13       |     | Y   |     |     |      |
| OpenDNS          | 208.67.220.2                |     | Y   |     |     |      |
| OpenDNS          | 208.67.222.2                |     | Y   |     |     |      |
| OpenDNS          | 208.67.220.123              |     | Y   |     |     |      |
| OpenDNS          | 208.67.220.220              |     | Y   |     |     |      |
| OpenDNS          | 208.67.222.123              |     | Y   |     |     |      |
| OpenDNS          | 208.67.222.222              |     | Y   |     |     |      |
| OpenDNS          | 204.194.232.200             |     | Y   |     |     |      |
| OpenDNS          | 204.194.234.200             |     | Y   |     |     |      |
| OpenDNS          | 2620:0:CCC:0:0:0:0:2        |     | Y   |     |     |      |
| OpenDNS          | 2620:0:CCD:0:0:0:0:2        |     | Y   |     |     |      |
| OpenDNS          | 2620:119:35:0:0:0:0:35      |     | Y   |     |     |      |
| OpenDNS          | 2620:119:35:0:0:0:0:123     |     | Y   |     |     |      |
| OpenDNS          | 2620:119:53:0:0:0:0:53      |     | Y   |     |     |      |
| OpenDNS          | 2620:119:53:0:0:0:0:123     |     | Y   |     |     |      |
| AdGuard          | 94.140.14.14                |     | Y   |     |     |      |
| AdGuard          | 94.140.14.140               |     | Y   |     |     |      |
| AdGuard          | 94.140.14.141               |     | Y   |     |     |      |
| AdGuard          | 94.140.14.15                |     | Y   |     |     |      |
| AdGuard          | 94.140.15.15                |     | Y   |     |     |      |
| AdGuard          | 94.140.15.16                |     | Y   |     |     |      |
| NextDNS(dns0.eu) | 185.253.5.0                 |     | Y   |     |     |      |
| NextDNS(dns0.eu) | 193.110.81.0                |     | Y   |     |     |      |
