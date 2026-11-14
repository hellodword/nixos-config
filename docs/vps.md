# VPS 与代理出口

VPS 使用独立锁定的 `nixpkgs-remote` 和轻量 profile：持久 ext4 根分区、首次启动扩容、磁盘 swap、SSH 公钥登录。BIOS 和 UEFI 由 inventory 的 `uefi` 选择。构建在维护机完成，Colmena 通过 SSH 复制闭包并激活，适合内存较小的 VPS。

VPS 的状态随根磁盘保留。这里采用普通持久系统，便于保留 SSH host key、服务数据、证书和可回滚的凭据。应用使用原生 NixOS 模块；每个节点的 `modules` 数组列出仓库相对路径，为完整系统组合不同服务。网络、磁盘和 SSH 来自同一份基础配置，bootstrap 与完整系统共用。

## 建立私有 inventory

从 [inventory 示例](../data/secrets/vps.example.yaml) 开始。示例地址、密钥和密码均需替换。每份订阅用 `openssl rand -hex 32` 生成一把独立的 `key`，以带引号的字符串保存；各节点的证书获取 token 也分别用该命令生成。`secrets` 表保存证书服务和上游出口等配置引用的秘密值。订阅路径使用 `python3 -c 'import uuid; print(uuid.uuid4())'` 生成的随机 UUID。

整份 YAML 作为 SOPS 的 binary 输入加密，密文以 YAML 保存到 `secrets/vps.sops.yaml`。节点名称、地址、关系和秘密字段名随正文一起加密。接收者在根目录 `.sops.yaml` 声明，可复用已有 age 身份；离线备份该身份。从仓库根目录准备维护工具：

```sh
nix develop .#vps
```

该环境提供生成材料、构建和部署所需的工具。SOPS 解密后，由 Python 生成材料；构建用 `nix build`，节点部署用 Colmena，Worker 发布用 Wrangler。各工具的文件与网络权限见[开发环境](validation.md#开发环境)。

```sh
(
  set -euo pipefail
  umask 077
  work=$(mktemp -d "$XDG_RUNTIME_DIR/vps.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  cp data/secrets/vps.example.yaml "$work/inventory.yaml"
  "${EDITOR:-vim}" "$work/inventory.yaml"
  mkdir -p secrets
  sops encrypt --input-type binary --output-type yaml \
    --filename-override secrets/vps.sops.yaml "$work/inventory.yaml" \
    > secrets/vps.sops.yaml
)
```

后续修改时，用下面的解密命令将内容写入同样的私密临时文件，编辑后重新加密。确认密文可解密后再替换原文件。维护机保存 age 私钥。

## 准备部署材料

一次解密生成本轮部署所需的文件。`key_file` 换成本机已有 age 身份路径，只有 SOPS 需要读取它；生成、构建和部署由当前用户执行。

```sh
set -o pipefail
key_file=/var/lib/sops-nix/keys.txt
sudo env SOPS_AGE_KEY_FILE="$key_file" "$(command -v sops)" \
  decrypt --input-type yaml --output-type binary secrets/vps.sops.yaml |
  python3 scripts/vps/prepare.py
```

输出保存在被 Git 忽略的 `tmp/vps/`：`metadata.json` 用于系统求值，`nodes/` 保存各节点凭据，`subscriptions/` 保存客户端文件，`workers/` 包含两个可独立发布的 Worker 目录。目录权限为 `0700`，文件权限为 `0600`。准备脚本只生成材料，完成后可分别检查、构建和部署；重新准备前先清理上一轮输出。

下文的 Nix 和 Colmena 命令从仓库根目录执行，通过 `--impure` 读取 `tmp/vps/metadata.json`。密码、隧道私钥和证书获取 token 由 Colmena 从绝对路径读取并单独下发，留在 Nix store 之外。拓扑、SSH 公钥和服务声明会进入系统闭包，因此私有系统在维护机本地构建和分发。

每台 VPS 只收到属于自身的代理服务配置和证书请求凭据，保存于 `/var/lib/site-vps/releases/<代次>/`。客户端只收到被授权的代理路径。age 身份和上游出口凭据不随订阅交付；Porkbun API 凭据只交给证书 Worker。

## 首次安装与日常部署

先填写节点的 `authorizedKeys`、磁盘设备和 `uefi`。安装后的系统采用 `eth0` 等顺序网卡名，默认公网接口为 `eth0`；多网卡机器按安装后名称填写 `interface`，它同时用于网络配置和代理转发。救援系统可能采用不同的网卡名。`dhcp: true` 使用供应商 DHCP；静态网络填写 `dhcp: false`、`addresses`、`gateway` 和 `nameservers`。`address` 是其他节点和部署端使用的 IPv4 地址。当前实例范围为 x86_64，`swapMiB` 默认 1024。

镜像大小由系统闭包决定，并预留根分区空间；首次启动将根分区和 ext4 文件系统扩展到目标磁盘，再创建 swap 文件。UEFI 镜像为启动区预留 512 MiB，BIOS 使用 GRUB；两者保留五个启动代次。磁盘容量无需写入 inventory，写盘前确认目标盘能容纳生成的镜像。

构建仅含系统和 SSH 公钥的 bootstrap 磁盘镜像：

```sh
nix build --impure --out-link result '.#vpsBootstrap.edge'
```

在维护机生成镜像后，可交给供应商导入，或通过 SSH 流式写入救援系统中的目标盘。下面的地址和设备名须替换为实际值。写盘会覆盖目标盘，先保存已有数据，并确认供应商控制台可用。

```sh
rescue=root@<救援地址>
ssh "$rescue" 'lsblk -d -o NAME,SIZE,MODEL'
# 确认 /dev/vda 是待安装的系统盘后再写入。
ssh "$rescue" 'dd of=/dev/vda bs=4M conv=fsync status=progress && sync' < result/nixos.img
ssh "$rescue" reboot
```

镜像由维护机直接传输到磁盘，救援系统只需处理流中的少量缓冲。将供应商启动方式设为清单中的 BIOS 或 UEFI，并从系统盘启动。

首次启动在目标机生成 SSH host key，其指纹写入 journal 和控制台。通过供应商控制台核对指纹后，把主机加入维护机的 `known_hosts`。如果控制台无法显示启动输出，可在启动过一次后回到救援系统，只读挂载根分区，用 `ssh-keygen -lf <挂载点>/etc/ssh/ssh_host_ed25519_key.pub` 核对。后续部署、重启和回滚保留该身份。

准备好下节的证书 Worker，再构建和部署完整系统。命令显式选择节点，按一台一台的顺序操作；维护机先完成构建，再向 VPS 传输闭包。

```sh
nix build --impure --no-link '.#colmenaHive.toplevel.edge'
colmena apply test --impure --on edge --parallel 1 --no-substitute
ssh root@<节点地址> 'systemctl status site-vps-proxy haproxy --no-pager'
# 确认 SSH 和实际代理请求正常后，保存为启动默认代次。
colmena apply switch --impure --on edge --parallel 1 --no-substitute
```

`test` 只改变当前运行系统，重启仍回到原来的启动默认代次。`switch` 同时设置启动默认代次。连接失效时可通过供应商控制台选择旧启动项；系统内回退可用：

```sh
sudo nix-env -p /nix/var/nix/profiles/system --rollback
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

旧凭据目录和证书对保留，供旧代次使用。清理旧系统代次后，再删除已确认没有系统引用的旧凭据目录。应用数据和运行凭据还需按各自恢复要求备份；系统重建不能代替数据恢复。

## 入口、出口与端口

顶层 `exits` 的每一项表示一个逻辑出口。`nodes` 列出承载它的 VPS：原生出口属于一台 VPS；同一个 SOCKS5、WireGuard 或 OpenVPN 上游可由多台 VPS 连接。例如，`us` 配置为 `nodes: [edge, west]` 后，两台 VPS 各自连接同一上游，任意入口均可将流量送到其中一台。

Trojan 使用 TCP 443。HAProxy 按客户端 SNI 将 TLS 字节流转发到承载 VPS；Hysteria2 使用 `20000 + udpSlot`，各入口按目标端口通过 DNAT/SNAT 转发到承载 VPS。两种协议都在承载 VPS 的 sing-box 中完成认证和解密，入口转发期间保留客户端到承载 VPS 的加密连接。`udpSlot` 在节点间唯一，取值为 0–9999；同一 VPS 的多个出口共用协议端口，通过认证身份区分。

供应商防火墙为所有 VPS 使用同一模板：允许 SSH 的实际 TCP 端口、TCP 443 和 **UDP 20000–29999**。这段 UDP 可能需要在供应商控制台手动放行。系统防火墙按清单中的实际节点端口开放监听和转发。

可声明的出口：

| `type` | `options` 的主要内容 |
| --- | --- |
| `native` | VPS 原生网络；可用原生 direct 参数指定源地址 |
| `wireguard` | `address`、`private_key`、`peers`；WARP 使用提取的标准 WireGuard 参数 |
| `socks` | `server`、`server_port`，以及所需用户名和密码 |
| `openvpn-client` | `server`、`server_port`、`network`、认证及 `tls` |

`options` 沿用 [sing-box 原生配置](https://sing-box.sagernet.org/configuration/endpoint/)，秘密值可写成 `{secret: 名称}`。[inventory 示例](../data/secrets/vps.example.yaml) 包含各类出口、订阅授权和秘密引用的完整写法。

WireGuard 和 OpenVPN 在 sing-box 用户态运行。`ipv6` 与 `udp` 描述该出口允许的目标能力：IPv6 默认关闭，UDP 默认开启；按供应商能力填写。入口和节点间转发使用 IPv4，laptop 既有 IPv4-only 策略继续生效。服务端拒绝代理到私网目标，VPS 本机应用通过自己的系统网络访问所需服务。

多台 VPS 共用一个上游账号时，可优先考虑 OpenVPN TCP，并按上游能力填写原生 `network` 等字段。

OpenVPN 的 `tls.server_name` 默认精确匹配服务端证书的 CN，填写供应商配置中 `verify-x509-name` 对应的名称。CA、客户端证书和私钥可用原生内联字段随配置下发；私钥放在 `secrets` 表中引用，见 [OpenVPN TLS 配置](https://sing-box.sagernet.org/configuration/endpoint/openvpn-client/#tls)。

需要在同一 TCP 443 提供网页时，在节点 `web` 映射中声明域名和本机 HTTP upstream，例如 `web: {app.example.com: 'http://127.0.0.1:8080'}`。该域名应与代理 SNI 不同且被证书覆盖。HAProxy 仅向本机 nginx 发送 PROXY v2，nginx 在 loopback 终止 HTTPS 并反代应用。

## 订阅与分流

`subscriptions` 声明独立的订阅，例如 `primary`、`guest`，同一订阅可供多个客户端使用。`exits` 决定授权的逻辑出口，`entries` 决定可选入口，`groups` 把站点用途绑定到出口。完整路径为“入口 × 承载 VPS × 出口 × 协议”，名称也按此顺序生成。例如 `path-edge-west-us-trojan` 表示连接 edge 的 TCP 443，由 west 解密，再从 `us` 上游发出。

每份订阅的 `key` 通过 HMAC-SHA256 为各出口、各协议派生密码；同一出口的所有承载 VPS 使用相同订阅身份。VPS 只收到自身承载的身份和上游凭据。调整入口、承载 VPS、订阅名称、订阅路径或用途选择时，已有密码保持稳定；更换密钥或出口标识会改变密码。

选择分为两层：

| 选择位置 | 作用 | 示例 |
| --- | --- | --- |
| 用途组，如 `cryptocurrency` | 选择逻辑出口 | 从 `us` 切到 `uk` |
| `exit-us` | 自动选择或固定一条完整路径 | `exit-us-auto`，或 `path-edge-west-us-trojan` |

用途组的 `exits` 是可选出口，`default` 是初始选择；多出口组明确填写，单出口组可省略。客户端已保存的有效选择优先。多个用途选中同一个出口时，共享该出口的路径选择；例如 `hideme` 和 `cryptocurrency` 都使用 `us`，固定 `exit-us` 的路径会同时影响这两个用途。

自动组每三分钟通过各条完整路径请求测试 URL，在可用路径中选择延迟较低者，100 毫秒容差用于减少频繁切换。测量覆盖入口连接、跨 VPS 转发和上游出站。入口或承载 VPS 故障后，后续探测将新连接移到仍可用的路径；探测间隔、连接超时和应用重连会影响实际恢复时间。健康的现有连接继续使用原路径，已断开的连接由应用重建。

排障时，在 `exit-us` 中固定具体路径，便可单独观察某个入口、承载 VPS 和协议。固定路径失效时仍保留这一选择，恢复自动切换需要重新选择 `exit-us-auto`。逻辑出口之间的切换由用户决定，例如全部 `us` 路径不可用时，可将用途改为 `uk`。

增加出口时，在顶层 `exits` 声明出站方式和承载 VPS，将名称加入订阅的 `exits`，再加入相应用途组。部署涉及的 VPS 并发布订阅后，客户端获得新的路径。

更换订阅 `key` 会同时更换该订阅所有出口、所有协议的密码。准备新部署材料后，先部署涉及的 VPS，再发布订阅 Worker，最后让客户端更新订阅；期间旧客户端会暂时无法连接。订阅地址可以保持原值。

Linux provider、官方移动 sing-box 和 Shadowrocket 共用这些关系和用途顺序。各客户端使用自己的原生远程规则格式及更新机制；规则来源和覆盖范围因此可能有差异。laptop 的接入与持久选择见[用途出口](network.md#用途出口)。VPS 的 `native` 指远端 VPS 原生网络，客户端 `direct` 指客户端自己的网络。

每份订阅的 `path` 为 `/<随机 UUID>`，拼接在 Cloudflare Worker 路由前缀之后。例如控制台 Route 为 `https://example.com/<worker-route-uuid>*`，则订阅地址为 `https://example.com/<worker-route-uuid><subscriptions.path>`。路由前缀由 Cloudflare 控制台维护，订阅路径在 inventory 中管理。

Worker 根据官方 sing-box 或 Shadowrocket 的 UA 选择内容，也可通过 `?client=` 显式选择，参数优先：

| 参数 | 返回内容 |
| --- | --- |
| `?client=linux` | 本项目使用的 provider |
| `?client=sing-box` | 官方 sing-box 完整配置 |
| `?client=shadowrocket` | Shadowrocket 配置 |

UA 无法识别时返回 400，提示指定 `client`。本项目下载 provider 时使用 `?client=linux`。Worker 通过 HTTPS 提供内容；完整订阅地址是访问凭据，应保存在私密位置。响应使用 `private, no-store`，Worker 访问日志保持关闭。

## 规则与 DNS

订阅的用途组决定匹配之后使用哪个出口，例如 `groups.cryptocurrency` 决定加密货币服务使用 `us` 还是其他出口。`proxy` 为必需组，用于通用海外规则和未绑定的可选用途，`hideme` 用于隐私站点及最终兜底；示例明确绑定两者。分类、顺序和重叠规则的行为统一在[网络用途出口](network.md#用途出口)说明。

移动客户端的基础配置分别位于 [sing-box-client.json](../data/network/sing-box-client.json) 和 [shadowrocket-client.conf](../data/network/shadowrocket-client.conf)。生成器插入订阅授权的路径及用途规则；远程规则的内容由客户端原生机制更新。Linux 的用途分类也读取同一目录，应用方式见[网络规则来源](network.md#规则来源与更新)。

VPS 有两种 DNS 用途：

- 系统 DNS 供系统服务、证书获取、时钟服务和上游服务器域名解析使用。systemd-resolved 通过严格 DoT 查询，按 TTL 缓存；当前解析器不可用时切换到另一台，恢复后继续使用当前可用服务器。`nodes.*.nameservers` 可用 `IP#TLS证书名` 覆盖默认列表。DHCP 与 RA 负责网络配置，解析器由清单指定。
- 代理目标的 DNS 经选中的逻辑出口发送。默认列表在 [vps-dns.json](../data/network/vps-dns.json)，`exits.*.dns` 可用原生 DNS server 数组覆盖。sing-box 并发查询各解析器，首先返回的正常应答或 NXDOMAIN 完成本次查询；SERVFAIL、拒绝和连接错误留给其他解析器继续处理，全部失败则返回失败。各出口使用各自的解析器实例及缓存。

例如，客户端将 `foo.example` 经 `path-edge-west-us-trojan` 发送：edge 转发 TLS 到 west；west 根据认证身份选择 `us`，从 `us` 查询目标 DNS，再从 `us` 连接解析结果。系统 DNS 只负责必要的基础设施域名，代理目标的解析与流量采用同一出口。

```sh
resolvectl status
resolvectl query example.com
journalctl -b -u systemd-resolved -u site-vps-proxy
```

时间同步配置与排查命令见 [chrony NTS](network.md#时间同步)。

## 发布 Worker 与管理证书

Wrangler 读取当前 Worker 的发布目录，使用 host 的网络、DNS 和代理。登录状态保存在项目根目录 `.wrangler/`，权限为 `0700`，已由 Git 忽略。从两个 Worker 子目录运行时共用这份登录状态；Cloudflare 权限由登录时授予的 scopes 决定。缓存、日志和临时构建文件的位置见[开发环境](validation.md#开发环境)。

已有 `~/.local/state/wrangler/` 登录状态时，可在首次使用新入口前复制到尚未创建的项目目录：

```sh
cp -a ~/.local/state/wrangler .wrangler
chmod 700 .wrangler
```

在仓库根目录登录时，沙箱使用空工作目录。按下面的范围授权，然后在浏览器打开终端显示的设备授权地址并输入代码：

```sh
wrangler login --device --browser=false \
  --scopes account:read \
  --scopes user:read \
  --scopes workers_scripts:write \
  --scopes workers_routes:write \
  --scopes zone:read
```

登录参数见 [Wrangler 文档](https://developers.cloudflare.com/workers/wrangler/commands/general/#login)。在 inventory 中填写各 Worker 名称和证书服务地址，发布在维护机显式执行：

```sh
(
  cd tmp/vps/workers/certificates
  wrangler deploy
  wrangler secret bulk secrets.json
)
(
  cd tmp/vps/workers/subscriptions
  wrangler deploy
)
```

首次发布后，在 Cloudflare 控制台对应 Worker 的 **Settings → Domains & Routes → Add → Route** 中，选择域名所属 zone 并填写 `https://example.com/<worker-route-uuid>*`；域名需有启用代理的 DNS 记录，详见 [Cloudflare Routes](https://developers.cloudflare.com/workers/configuration/routing/routes/)。两个 Worker 使用各自的路由前缀。后续发布保留控制台中的路由，生成的 Wrangler 配置关闭 workers.dev 和预览地址。

`workers.certificates.url` 填写证书 Worker 路由去掉末尾 `*` 的完整 HTTPS 基地址；节点名称会追加在该地址之后，例如 `https://example.com/<certificate-route-uuid>/edge`。

证书 Worker 从 Porkbun 获取声明域名的证书和私钥，节点通过自己的 bearer token 获取。每台 VPS 首次启用时获取一次，此后每日带随机延迟检查；证书链、域名、剩余有效期和密钥匹配全部通过后，原子切换整对证书并重启使用它的服务。下载或验证失败时继续使用现有证书。状态保存在 `/var/lib/site-vps-certificate/`。

同一通配符证书的私钥由使用它的 VPS 共享；任一这些节点失陷都需要按这个信任范围轮换证书。Porkbun API 凭据只存在证书 Worker 的 secret binding 中，节点仅持有取证 token。

## 清理部署材料

本轮 VPS 部署和 Worker 发布全部完成后，在仓库根目录删除解密派生文件。Wrangler 登录状态独立保留，后续可直接重新准备和发布；需要撤销维护机登录时运行 `wrangler logout`。

```sh
rm -r -- tmp/vps
```

## 撤销订阅

更换订阅地址时生成新的 UUID，更新 `path` 并重新发布订阅 Worker，再把新地址交给使用者。撤销整份订阅时删除对应条目，发布订阅 Worker 并部署相关 VPS，使下载入口和已有代理凭据一并失效。

## 更新 VPS 包集

```sh
nix flake update nixpkgs-remote
```

VPS 与 laptop 分别跟踪 nixos-unstable；上面的命令只推进 VPS 的锁定版本。验证使用公开合成节点，从实际 bootstrap 镜像启动，覆盖低内存安装和 Colmena 部署；真实节点仍在维护机单独构建。具体命令见[验证指南](validation.md)，定时更新和合并条件见[CI](ci.md#入口和候选提交)。
