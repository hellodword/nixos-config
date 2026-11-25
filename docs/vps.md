# VPS 与代理出口

维护机统一解密私有声明并生成节点凭据、Worker 包与客户端订阅，经 Colmena 部署 VPS、经 Wrangler 发布 Cloudflare Workers。

## 准备部署材料与日常更新

在仓库根目录进入 VPS 维护环境：

```sh
nix develop .#vps
```

### 1. 编辑私有 inventory 与生成材料

首次建立时以 [vps.example.yaml](../data/secrets/vps.example.yaml) 为模板创建 `secrets/vps.sops.yaml`（编辑方式见 [凭据指南](secrets.md#创建与编辑)）：每份订阅的 `key` 与各节点证书获取 token 分别用 `openssl rand -hex 32` 生成，订阅 `path` 与可选 `http-origin-prefix` 用随机 UUID 生成。

若存在上一轮残留的 `tmp/vps/`，确认部署已完成后先删除，再一次解密生成本轮全部材料：

```sh
node=edge
subscription=primary

set -o pipefail
sops decrypt secrets/vps.sops.yaml | python3 scripts/vps/prepare.py
```

输出位于被 Git 忽略的 `tmp/vps/`（目录 `0700`、文件 `0600`）：
- `metadata.json`：供 Nix 与 Colmena `--impure` 求值（含节点拓扑、端口及根据节点服务配置计算出的 `release` 摘要）；
- `nodes/<节点>/<release>/`：`proxy.json`、`certificate.json` 及启用 `modules/vps/http-origin.nix` 时的 `http-origin-prefix`，由 Colmena `deployment.keys` 以 `0600` 权限直接上传至目标机 `/var/lib/site-vps/releases/<release>/`，密文文件本身不进入 `/nix/store`，部署阶段也无需再次调用 SOPS；
- `workers/{certificates,subscriptions}/`：两个独立的 Cloudflare Worker 发布目录；
- `subscriptions/<名称>/`：生成的 `hy2`、`trojan`、`trojan-chain` 各端配置。

### 2. 日常更新范围速查

| 变更内容 | 执行动作 |
| --- | --- |
| 用途规则、默认出口、路径显示名、客户端 DNS、订阅路径/名称 | 生成材料 → [发布订阅 Worker](#4-发布与验证-workers) → 更新客户端 |
| 订阅密钥 `key`、授权出口、撤销订阅 | 部署并重启涉及的 VPS → 验证代理 → 发布订阅 Worker → 更新客户端 |
| 节点入口、出口承载、上游参数、`http-origin-prefix` | 部署、重启并验证涉及的 VPS；客户端可见路径变化时同步发布订阅 |
| 系统模块、SSH 服务端、VPS 包集（`nixpkgs-remote` / `colmena`） | 对节点执行 `colmena apply boot` → 重启后验证服务与代理请求 |
| 证书 Worker 凭据或节点取证 token | 先发布证书 Worker 并本机验证取证；token 变更时同步部署对应节点 |

本地手动推进 VPS 依赖组：

```sh
nix flake update nixpkgs-remote colmena cloudflare-ips-v4 cloudflare-ips-v6
```

### 3. 更新已有 VPS（Colmena 部署与重启）

维护机的 SSH 与代理连接应避开当前正在重启的节点。先记录目标机当前系统代次，再执行 `boot` 部署并在维护窗口重启：

```sh
ssh_host=$(jq -r --arg node "$node" '.nodes[$node].sshHost' tmp/vps/metadata.json)
ssh "$ssh_host" '
  readlink -f /run/current-system
  readlink /nix/var/nix/profiles/system
  nix-env -p /nix/var/nix/profiles/system --list-generations
'

colmena apply boot --impure --on "$node" --parallel 1 --no-substitute &&
expected_system=$(ssh "$ssh_host" 'readlink -f /nix/var/nix/profiles/system') &&
printf '下次启动系统：%s\n' "$expected_system"

ssh "$ssh_host" 'systemctl reboot'
```

`boot` 交付新系统与新 `<release>` 凭据目录，重启前运行中的代次继续读取自身引用的旧凭据。SSH 恢复后核对运行代次与核心服务（需要立即试运行且保留原默认启动项时可用 `colmena apply test`，立即切换并设为默认启动项可用 `colmena apply switch`）：

```sh
running_system=$(ssh "$ssh_host" 'readlink -f /run/current-system')
test "$running_system" = "$expected_system" &&
ssh "$ssh_host" 'systemctl is-active site-vps-proxy.service haproxy.service'
```

### 4. 发布与验证 Workers

首次在仓库根目录执行设备登录（状态保存在根 `.wrangler/`，对沙箱内其他命令遮蔽）：

```sh
wrangler login --device --browser=false \
  --scopes account:read --scopes user:read \
  --scopes workers_scripts:write --scopes workers_routes:write --scopes zone:read
```

发布证书 Worker 并在本机验证节点取证（首次部署需在 Cloudflare 控制台绑定与 `workers.certificates.url` 对应的 `<route-uuid>*` 路由）：

```sh
(cd tmp/vps/workers/certificates && wrangler deploy && wrangler secret bulk secrets.json)

release=$(jq -r --arg node "$node" '.nodes[$node].release' tmp/vps/metadata.json)
python3 scripts/vps/certificate.py \
  --request "tmp/vps/nodes/$node/$release/certificate.json" \
  --state "tmp/vps/certificates/$node" \
  --ca-file /etc/ssl/certs/ca-certificates.crt
```

发布订阅 Worker 并核对下载内容一致（首次部署同样在控制台绑定订阅 `<route-uuid>*` 路由）：

```sh
(cd tmp/vps/workers/subscriptions && wrangler deploy)

read -r -s -p '订阅的完整 HTTPS 地址：' subscription_url; printf '\n'
curl --fail --show-error "${subscription_url}?client=linux" \
  --output "tmp/vps/subscriptions/$subscription/downloaded-linux.json"
cmp "tmp/vps/subscriptions/$subscription/linux.json" \
  "tmp/vps/subscriptions/$subscription/downloaded-linux.json"
unset subscription_url
```

### 5. 验证代理请求与清理材料

在 `vps` 开发环境中抽取单条路径（如 `${node} · native · Trojan` 或跨节点 `edge → west · native · HY2`）启动本地探测：

```sh
provider="tmp/vps/subscriptions/$subscription/trojan/linux.json"
jq -r '.outbounds[].tag' "$provider"
probe_path="${node} · native · Trojan"

umask 077
install -d -m 700 tmp/devtools/network
jq -e --arg path "$probe_path" '
  (first(.outbounds[] | select(.tag == $path)) // error("proxy path not found")) as $outbound
  | {
      inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: 11080}],
      outbounds: [$outbound],
      route: {final: $path}
    }
' "$provider" > tmp/devtools/network/vps-probe.json &&
sing-box check -c tmp/devtools/network/vps-probe.json &&
sing-box run -c tmp/devtools/network/vps-probe.json
```

在另一终端执行 `curl --fail --show-error --max-time 20 --socks5-hostname 127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace` 核对出口 IP（验证 HY2 时读取 `"tmp/vps/subscriptions/$subscription/linux.json"`）。本轮全部部署、验证与客户端更新完成后清理临时材料：

```sh
rm -rf -- tmp/vps tmp/devtools/network/vps-probe.json
```

### 6. 回退系统与旧凭据自动回收

在目标 VPS 的 root shell（或通过供应商控制台选择旧启动项）中切换回指定代次：

```sh
nix-env -p /nix/var/nix/profiles/system --list-generations
generation=42
nix-env -p /nix/var/nix/profiles/system --switch-generation "$generation" &&
/nix/var/nix/profiles/system/bin/switch-to-configuration boot &&
systemctl reboot
```

各节点内置 `site-vps-gc.service` 与每周 `site-vps-gc.timer`（系统激活时亦自动运行）：自动扫描当前运行系统与 `/nix/var/nix/profiles/system-*-link` 仍引用的凭据及证书目录，保留所有可回退代次所需的 `/var/lib/site-vps/releases/*` 和 `/var/lib/site-vps-certificate/*`，仅清理已无任何系统代次引用的陈旧目录。

## 初次部署与救援写盘

首次上线新节点时，先完成材料生成与 Workers 发布，并确认供应商防火墙放行实际 SSH TCP 端口、TCP 443、UDP `20000–29999`（启用 `http-origin` 时另放行 TCP 80）。

### 1. 核对参数与构建镜像

节点架构为 `x86_64-linux`；`uefi` 选择 UEFI（`systemd-boot`）或 BIOS（`GRUB`）；静态网络设 `dhcp: false` 并提供 `addresses`（CIDR）、`gateway` 与 `nameservers`（`IP#TLS证书名`）。

```sh
ssh_host=$(jq -r --arg node "$node" '.nodes[$node].sshHost' tmp/vps/metadata.json)
ssh -G "$ssh_host" | rg '^(hostname|port|user|identityfile|proxycommand) '
install -d -m 700 tmp/vps/images tmp/vps/systems
nix build --impure --out-link "tmp/vps/images/$node" ".#vpsBootstrap.$node"
nix build --impure --out-link "tmp/vps/systems/$node" ".#colmenaHive.toplevel.$node"
```

### 2. 进入救援环境

- **Virtualizor Rescue Mode**：在面板启用 [Rescue Mode](https://www.virtualizor.com/docs/enduser/rescue-mode) 并设置临时 root 密码，SSH 连接就绪后继续写盘；校验完成后关闭 Rescue Mode 重启。
- **Oracle Cloud（UEFI netboot.xyz + Tiny Core）**：将 `https://boot.netboot.xyz/ipxe/netboot.xyz.efi` 放入 `/boot/EFI/netboot/netboot.xyz.efi`，连接 [串口控制台](https://docs.oracle.com/en-us/iaas/Content/Compute/References/serialconsole.htm) 重启按 `Esc` 从该文件引导；在 iPXE shell 执行 `set cmdline console=ttyS0,115200n8 noswap norestore rdinit=/bin/sh -- -i` 与 `exit`，选择 `Live CDs → Tiny Core Linux → x86_64 → CorePure`；早期 shell 执行 `printf '\nttyS0::respawn:/bin/sh\n' >> /etc/inittab && exec /init`，进入系统后运行 `su - tc -c 'tce-load -wi openssh bash coreutils util-linux gzip'`，设置 `passwd root`、`touch /etc/sysconfig/superuser` 并启动 `/usr/local/etc/init.d/openssh start`。

### 3. 流式写盘、SHA-256 回读与首次激活

在维护机连接救援 SSH，确认未挂载的目标整盘（**写盘会覆盖整块目标磁盘**），流式解压写入并在远端回读等长字节校验 SHA-256：

```sh
read -r -p '救援地址：' rescue_address
read -r -p '救援 SSH 端口 [22]：' rescue_port; rescue_port=${rescue_port:-22}
read -r -p '救援用户 [root]：' rescue_user; rescue_user=${rescue_user:-root}

install -d -m 700 tmp/vps/install
rescue_ssh=(
  -T -F /dev/null -p "$rescue_port" -o BatchMode=no
  -o PreferredAuthentications=keyboard-interactive,password
  -o StrictHostKeyChecking=ask -o GlobalKnownHostsFile=/dev/null
  -o "UserKnownHostsFile=$PWD/tmp/vps/install/$node.known_hosts"
  "$rescue_user@$rescue_address"
)

ssh "${rescue_ssh[@]}" 'lsblk -b -p -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT; swapon --show; findmnt -rn -o SOURCE,TARGET'
read -r -p '救援环境中的目标整盘：' rescue_disk

image=$(realpath -e "tmp/vps/images/$node/nixos.img")
compressed="$PWD/tmp/vps/install/$node.img.gz"
(umask 077 && gzip -n -6 -c -- "$image" > "$compressed.partial" && mv -- "$compressed.partial" "$compressed")

(
  set -euo pipefail
  image_bytes=$(stat -Lc '%s' "$image")
  local_hash=$(sha256sum -- "$image" | awk '{print $1}')
  disk_bytes=$(ssh "${rescue_ssh[@]}" "$(printf 'test -b %q && blockdev --getsize64 %q' "$rescue_disk" "$rescue_disk")")
  (( disk_bytes >= image_bytes ))
  ssh "${rescue_ssh[@]}" "$(printf 'bash -o pipefail -c %q' "$(printf 'gzip -dc | dd of=%q bs=4M iflag=fullblock conv=fsync status=progress' "$rescue_disk")")" < "$compressed"
  remote_hash=$(ssh "${rescue_ssh[@]}" "$(printf 'bash -se -- %q %q' "$rescue_disk" "$image_bytes")" <<'RESCUE' | awk '{print $1}'
set -o pipefail
sync
blockdev --flushbufs "$1"
head -c "$2" -- "$1" | sha256sum
RESCUE
  )
  test "$local_hash" = "$remote_hash"
  printf '回读 SHA-256 校验通过：%s\n' "$remote_hash"
)
```

从系统盘重启后，核对控制台输出的首次 SSH host key 指纹并写入 `known_hosts`（首次启动自动扩容 ext4 根分区并建立 swap），再通过 Colmena 完成切换与重启确认：

```sh
ssh "$ssh_host" 'df -h /; swapon --show; ip -4 address; resolvectl status'
colmena apply test --impure --on "$node" --parallel 1 --no-substitute
# 完成代理路径探测后持久化为启动代次：
colmena apply switch --impure --on "$node" --parallel 1 --no-substitute
ssh "$ssh_host" 'systemctl reboot'
```

## 节点扩展模块、协议与端口

### 节点可选模块（`nodes.<节点>.modules`）

- **`modules/vps/http-origin.nix`（Cloudflare TCP 80 回源）**：在 `secrets.<节点>-http-origin-prefix` 声明 `/随机UUID`（匹配 `^/[A-Za-z0-9_-]+$`），`prepare.py` 将其纳入节点 `release` 计算并通过 Colmena 下发，服务经 `LoadCredential` 读取。Nginx 在 TCP 80 仅将匹配该秘密前缀的路径（保留子路径、查询参数、WebSocket 与 `CF-Connecting-IP`）反代至本机 `127.0.0.1:8080`，其余路径返回 `404`；防火墙仅放行锁定的 Cloudflare IPv4/IPv6 地址段访问 TCP 80（同时丢弃来自 Cloudflare 地址段的 TCP/UDP 443）。
- **`modules/vps/docker.nix`（容器运行环境）**：启用 Docker、`local` 轮转日志驱动与每周自动 `autoPrune`，放行 `docker0` 与 `br-*` 转发并兼容节点间代理转发。
- **同端口 HTTPS 站点（`nodes.<节点>.web`）**：如 `web: {app.example.com: 'http://127.0.0.1:8080'}`，HAProxy 在 TCP 443 按 SNI 将网页流量经 PROXY v2 转交本机 loopback Nginx 终止 TLS，与代理 SNI 共存。

### 入口、出口与转发拓扑

- **Trojan（TCP 443）** 由入口 HAProxy 按客户端 SNI 透传 TLS 字节流至承载 VPS；**Hysteria2（UDP `20000 + udpSlot`）** 由入口 nftables 按端口 DNAT/SNAT 转发至承载 VPS。两类连接均在承载 VPS 的 `sing-box` 内完成认证、解密与出站。
- `exits` 支持 `native`、`wireguard`、`socks` 与 `openvpn-client`（`options` 支持 `{secret: 名称}` 引用），按 `ipv6`（默认 `false`）与 `udp`（默认 `true`）生成服务端协议限制与客户端 `udp-relay` 配置。

## 订阅与客户端导入

订阅 URL 为 Cloudflare 路由前缀拼接 `subscriptions.<名称>.path`（未知订阅 UUID 统一返回 `404`），支持 `?client=linux`、`?client=sing-box`、`?client=shadowrocket`、`?client=shadowrocket-subscribe`、`?client=shadowrocket-config` 及 `&mode=hy2|trojan|trojan-chain`（未传 `client` 时按官方客户端 UA 识别）。

- **移动 sing-box**：直接导入默认 HY2 与 `&mode=trojan`；`trojan-chain` 下载后在 `tmp/devtools/network/` 与本地 `chain.json` 执行 `sing-box merge trojan-chain.json -c sing-box.json -c chain.json` 后私下导入设备。
- **Shadowrocket**：可直接导入 `?client=shadowrocket` 完整配置，或用以下脚本打印一键导入 URI：
  ```sh
  python3 - "$subscription" <<'PY'
  import base64, getpass, json, sys
  from pathlib import Path
  from urllib.parse import quote
  directory = Path("tmp/vps/subscriptions") / sys.argv[1]
  url = getpass.getpass("订阅的完整 HTTPS 地址：").strip()
  for mode in ("hy2", "trojan", "trojan-chain"):
      folder = directory if mode == "hy2" else directory / mode
      name = json.loads((folder / "metadata.json").read_text())["name"]
      nodes = base64.b64encode(f"{url}?client=shadowrocket-subscribe&mode={mode}".encode()).decode()
      print(f"\n{name} ({mode})")
      print(f"完整配置  shadowrocket://config/add/{url}?client=shadowrocket&mode={mode}")
      print(f"节点订阅  shadowrocket://add/sub://{nodes}?remark={quote(name, safe='')}")
      print(f"分流配置  shadowrocket://config/add/{url}?client=shadowrocket-config&mode={mode}")
  PY
  ```

更换 Shadowrocket 的 DNS 上游时，在共享声明中编辑直连用的 `direct` 组或经首页节点查询的 `proxy` 组。重新生成并发布订阅 Worker 后，完整导入的客户端刷新完整配置。分离导入时，DNS 和规则随分流配置更新，节点随节点订阅更新。[DNS 上游声明](../data/network/dns-upstreams.toml)

### Shadowrocket 的连接与 DNS

在「全局路由」选「配置」，保持首页节点和用途组的选择不变。选一个有 TXT 记录的域名，分别打开网站和查询 TXT，按时间和完整域名对照连接日志与 DNS 日志。使用未缓存的查询才能观察上游请求。

| 操作 | 如何读日志 |
| --- | --- |
| 打开网站 | 普通 A 查询先返回 Fake IP。应用连接这个地址时，Shadowrocket 按域名匹配规则。直连需要真实地址时使用 `direct-dns-server`。代理连接将域名交给节点，由节点通过所选出口解析。 |
| 单独查询同一域名的 TXT | 即使网站连接命中 `DIRECT`，独立的 TXT 查询仍可走 `dns-server`。应用也会查询 `SRV` 来发现服务，或查询 `HTTPS` 记录取得连接参数。 |

连接日志显示 `FINAL` 时，手机可能已经查询过该域名。`DOMAIN-KEYWORD,.,…` 放在 `FINAL` 前，让其余含点域名也能按域名匹配代理组。对于列在 `always-real-ip` 中的域名，A 查询本身就需要真实地址。

默认 DoH 和备用 DoT 都通过 `#proxy` 使用首页节点。切换用途组会改变匹配该组的连接出口，切换首页节点才会改变这两项 DNS 的代理路径。若使用 `#proxy=名称`，名称须指向具体节点。

排查明文 DNS 时，用 `nslookup -type=TXT "$domain"` 查询默认解析器，再用 `dig @"$server" "$domain" TXT` 显式查询 UDP 53，加 `+tcp` 可测 TCP 53。选一个由隧道接管的地址作为 `$server`，显式查询会命中 `REJECT`，默认 TXT 查询仍可经加密 DNS 得到应答。

外部 DNS 探测记录的是递归解析器向权威服务器查询时使用的地址。要确认手机实际发出的明文 DNS，可在 Wi-Fi 网关的局域网接口按设备抓取目的端口为 53 的流量。这也能查到发往 `tun-excluded-routes` 中地址、绕过隧道的查询。

## 服务端 DNS 与泛域名证书更新

- **DNS**：VPS 宿主系统服务使用 `systemd-resolved` 严格 DoT（`resolvectl status` 查看）；代理目标的域名解析由承载 VPS 的 `sing-box` 经对应逻辑出口并发查询 [vps-dns.json](../data/network/vps-dns.json)（或 `exits.*.dns`）。
- **证书更新**：证书 Worker 在 Cloudflare Edge 从 Porkbun 拉取泛域名证书，各节点 `site-vps-certificate` 持各自的 Bearer token（常量时间比对）拉取并校验链、SAN、私钥匹配与有效期（首次无已装证书时允许安装未过期的短期有效证书，后续续期要求剩余不少于 7 天），原子切换后通过 `onSuccess` 触发 `site-vps-certificate-reload.service` 同步重启代理与 Web 服务，随后清除变更标记；Porkbun API 密钥仅保存在证书 Worker 的 secret binding 中。
