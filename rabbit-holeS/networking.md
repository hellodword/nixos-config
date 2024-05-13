# networking

## wireless

## cproxy

> 利用 cgroups 的临时流量处理工具

- interface
- ipv4/6
- fwmark
- trace

## tailscale

> https://kiprey.github.io/2023/11/tailscale-derp/#%E5%85%AD%E3%80%81DERP-%E6%90%AD%E5%BB%BA%E6%80%BB%E7%BB%93%E6%BC%94%E7%A4%BA

```sh
git clone --depth=1 https://github.com/tailscale/tailscale
cd tailscale

mkdir -p dist

docker kill tailscale-builder && sleep 1s || true
docker rm tailscale-builder || true

docker run --name tailscale-builder --rm -v "$(pwd)":/tmp/src -w /tmp/src -d golang:1-bullseye sleep infinity

docker exec tailscale-builder \
    go build -x -v -trimpath -ldflags "-s -w" -buildvcs=false -o dist/derper ./cmd/derper

docker exec tailscale-builder \
    go build -x -v -trimpath -ldflags "-s -w" -buildvcs=false -o dist/derpprobe ./cmd/derpprobe

docker kill tailscale-builder && sleep 1s || true
docker rm tailscale-builder || true


export DERP_HOST="kiprey-derp"


mkdir -p dist/certdir && cd dist/certdir
openssl genpkey -algorithm RSA -out ${DERP_HOST}.key
openssl req -new -key ${DERP_HOST}.key -out ${DERP_HOST}.csr
openssl x509 -req \
		-days 36500 \
		-in ${DERP_HOST}.csr \
		-signkey ${DERP_HOST}.key \
		-out ${DERP_HOST}.crt \
		-extfile <(printf "subjectAltName=DNS:${DERP_HOST}")


# on server
export DERP_HOST="kiprey-derp"
export DERP_PORT=8888
export STUN_PORT=8889
./derper \
    -c ./.derper.key \
    -a :${DERP_PORT} -http-port -1 \
    -stun-port ${STUN_PORT} \
    -hostname ${DERP_HOST} \
    --certmode manual \
    -certdir ./certdir

curl -k https://${DERP_HOST}:${DERP_PORT} --resolve ${DERP_HOST}:${DERP_PORT}:<server ip> -v
```

```ini
# derper-verifier.service
[Unit]
Description=DERP Verifier Service
After=network.target nss-lookup.target

[Service]
Restart=on-failure
RestartPreventExitStatus=23

User=root

ExecStart=/usr/local/bin/derper-verifier -path /usr/local/etc/derper-verifier/verifier.json

Type=simple

[Install]
WantedBy=multi-user.target
```

```ini
# derper.service
[Unit]
Description=DERP Service
After=network.target nss-lookup.target derper-verifier.service

[Service]
Restart=on-failure
RestartPreventExitStatus=23

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

DynamicUser=true
LogsDirectory=derper
RuntimeDirectory=derper
StateDirectory=derper

RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

ExecStartPre=+/usr/sbin/sysctl -w net.core.rmem_max=2500000
ExecStart=/usr/local/bin/derper -c /var/lib/derper/.derper.key -a :8888 -http-port -1 -stun-port 8889 -hostname "kiprey-derp" --certmode manual -certdir /var/lib/derper/certdir --verify-clients=false --verify-client-url-fail-open=false --verify-client-url=http://127.0.0.1:3000

NoNewPrivileges=true
LockPersonality=true

MemoryDenyWriteExecute=true
NoNewPrivileges=true
PrivateMounts=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
RemoveIPC=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
SystemCallFilter=~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid
SystemCallFilter=setrlimit
Type=simple

[Install]
WantedBy=multi-user.target
```
