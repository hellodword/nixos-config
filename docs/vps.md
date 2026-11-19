# VPS 与代理出口

在维护机准备声明与凭据，发布 Workers，再按节点安装或更新 VPS。节点上线后验证代理路径，并将订阅交给客户端使用。

## 准备部署材料

从仓库根目录进入维护环境。下文维护机上的命令在这个 Bash 中执行，节点与救援系统中的命令会单独标明。

```sh
nix develop .#vps
```

该环境提供 SOPS、材料生成、构建和部署所需工具。各工具的文件与网络权限见[开发环境](validation.md#开发环境)。

### 建立私有 inventory

inventory 保存为 `secrets/vps.sops.yaml`，密钥准备与编辑方法见[凭据指南](secrets.md#创建与编辑)。首次填写时从 [inventory 示例](../data/secrets/vps.example.yaml) 开始，替换示例地址、密钥和密码；日常维护直接编辑已有文件：

```sh
mkdir -p secrets
sops secrets/vps.sops.yaml
```

每份订阅用 `openssl rand -hex 32` 生成一把独立的 `key`，以带引号的字符串保存；各节点的证书获取 token 也分别用该命令生成。`secrets` 表保存证书服务和上游出口等配置引用的秘密值。订阅路径使用 `python3 -c 'import uuid; print(uuid.uuid4())'` 生成的随机 UUID。

分批安装时声明本轮准备上线及已有的节点。重装或重启前，将维护机的代理与 SSH 连接切到其他可用路径；与其他部署并存时，为证书和订阅 Worker 选择独立名称及路由前缀。

选择本轮操作的节点和用于验证的订阅，名称与 YAML 中的键一致：

```sh
node=edge
subscription=primary
```

### 生成本轮材料

若已有上一轮的 `tmp/vps/`，确认该轮部署和发布已经完成，再按[清理部署材料](#清理部署材料)删除旧输出。编辑完 inventory 或相关项目文件后，一次解密生成本轮所需材料：

```sh
set -o pipefail
sops decrypt secrets/vps.sops.yaml |
  python3 scripts/vps/prepare.py
```

输出保存在被 Git 忽略的 `tmp/vps/`：`metadata.json` 用于系统求值，`nodes/` 保存各节点凭据，`subscriptions/` 保存客户端文件，`workers/` 包含两个可独立发布的 Worker 目录。目录权限为 `0700`，文件权限为 `0600`。本轮各节点和 Worker 共用这次生成结果，分别构建和部署。

`prepare.py` 的声明错误包含字段路径，YAML 语法错误提供行列号；对照 [vps.example.yaml](../data/secrets/vps.example.yaml) 修正后重新生成。

Nix 和 Colmena 命令通过 `--impure` 读取 `tmp/vps/metadata.json`。密码、隧道私钥和证书获取 token 由 Colmena 从绝对路径读取并单独下发，留在 Nix store 之外。拓扑、SSH 公钥和服务声明会进入系统闭包，因此私有系统在维护机本地构建和分发。

每台 VPS 收到自身服务所需的凭据，其中代理配置和证书请求保存在 `/var/lib/site-vps/releases/<代次>/`。客户端只收到被授权的代理路径。age 身份和上游出口凭据不随订阅交付；Porkbun API 凭据只交给证书 Worker。

### 节点模块与秘密

`nodes.<节点>.modules` 引用仓库内的 NixOS 模块，服务配置和防火墙规则在模块中声明。完整系统的模块可使用 `inputs` 读取锁定的 flake 输入，使用 `vpsSecretsFile` 获取本轮加密 inventory 的路径。

模块通过 Colmena 的 `deployment.keys.keyCommand` 调用维护机上的 `sops decrypt --extract`，从 YAML 的 `secrets` 表提取所需值。部署沿用维护机的 SOPS 身份，节点只接收提取出的文件。服务用 `LoadCredential` 或自身的秘密文件选项读取；需要将秘密嵌入配置时，在启动前生成运行时配置并执行服务自身的配置检查。声明方式见 [HTTP origin 模块](../modules/vps/http-origin.nix)，Colmena 参数见[密钥交付说明](https://colmena.cli.rs/unstable/features/keys.html)。

例如，节点上的应用监听 `127.0.0.1:8080`，通过以下声明提供 HTTP 入口：

```yaml
nodes:
  edge:
    modules:
      - modules/vps/http-origin.nix
secrets:
  edge-http-origin-prefix: /替换为随机UUID
```

用 `python3 -c 'import uuid; print(uuid.uuid4())'` 生成 UUID，在前面加 `/`，填入 `secrets.<节点>-http-origin-prefix`。前缀只包含一个由字母、数字、连字符或下划线组成的路径段。假设前缀为 `/abc`，nginx 将 `/abc`、`/abc/` 及其子路径（如 `/abc/items?q=1`）连同查询参数原样转给应用。其他路径返回 404。转发保留方法、正文和 Host，支持 WebSocket，并将 Cloudflare 提供的客户端地址和外部协议传给应用。

该模块监听 TCP 80，并在 IPv4、IPv6 上允许 Cloudflare 地址段访问；其他外部来源的 TCP 80，以及 Cloudflare 来源的 TCP/UDP 443 被丢弃。loopback 可用于本机诊断，其余 443 流量沿用节点已有策略。供应商防火墙也需要放行 TCP 80。地址段由锁定的 Cloudflare 输入提供，随 remote 更新、部署生效。来源限制确认的是 Cloudflare 网络，秘密路径用于区分可访问的入口。

若维护机通过 `sudo` 读取 age 私钥，Colmena 上传前缀时会复用当前终端的 sudo 授权。授权过期时部署直接报错，在同一终端执行 `sudo -v` 后重试原部署命令即可。

前缀文件以 root `0600` 保存到 `/var/lib/site-http-origin/credentials/<密文摘要>/`。每版加密 YAML 使用独立目录，`apply boot` 交付的新前缀在重启后启用，当前代次和回滚继续读取各自的文件。重新保存 YAML 会产生新目录；清理旧系统代次时，可一并清理已无代次引用的凭据目录。

## 部署 Workers

两个 Worker 分别发布。证书 Worker 在节点取证前就绪；订阅 Worker 提供客户端配置。首次安装可以先发布订阅，节点通过请求验证后再[切换客户端](#切换客户端)。已有订阅的认证或连接参数变化时，先完成相关节点的部署与验证，再发布对应订阅；仅调整客户端内容时，按[仅更新订阅](#仅更新订阅)处理。

Wrangler 读取当前 Worker 的发布目录，使用 host 的网络、DNS 和代理。登录状态保存在项目根目录 `.wrangler/`，两个 Worker 共用这份状态；文件访问与缓存位置见[开发环境](validation.md#开发环境)。在仓库根目录登录，浏览器打开终端给出的设备授权地址并输入代码：

```sh
wrangler login --device --browser=false \
  --scopes account:read \
  --scopes user:read \
  --scopes workers_scripts:write \
  --scopes workers_routes:write \
  --scopes zone:read
```

已有项目登录状态时可直接发布。参数见 [Wrangler 登录文档](https://developers.cloudflare.com/workers/wrangler/commands/general/#login)。

### 发布证书 Worker

```sh
(
  cd tmp/vps/workers/certificates
  wrangler deploy && wrangler secret bulk secrets.json
)
```

在新证书 Worker 的 **Settings → Domains & Routes → Add → Route** 中选择 zone，填写 `https://example.com/<certificate-route-uuid>*`。域名需要启用代理的 DNS 记录；路由前缀与 inventory 的 `workers.certificates.url` 对应。控制台操作见 [Cloudflare Routes](https://developers.cloudflare.com/workers/configuration/routing/routes/)。后续发布保留这些路由。

### 检查节点证书

用所选 `node` 的请求配置获取证书，确认 token、Porkbun 凭据、证书域名及有效期都可用。处理另一台时先修改 `node`，再执行相同命令：

```sh
(
  set -e
  release=$(jq -r --arg node "$node" '.nodes[$node].release' tmp/vps/metadata.json)
  python3 scripts/vps/certificate.py \
    --request "tmp/vps/nodes/$node/$release/certificate.json" \
    --state "tmp/vps/certificates/$node" \
    --ca-file /etc/ssl/certs/ca-certificates.crt
)
```

取回的证书与私钥保存在 `tmp/vps/certificates/`，部署材料清理时一并删除。节点后续独立获取和更新证书，见[证书更新](#证书更新)。

### 发布订阅 Worker

从仓库根目录发布本轮生成的订阅 Worker：

```sh
(
  cd tmp/vps/workers/subscriptions
  wrangler deploy
)
```

首次发布时，在该 Worker 的 **Settings → Domains & Routes → Add → Route** 中配置 `https://example.com/<subscription-route-uuid>*`，后续发布沿用该路由。完整订阅 URL 是这个前缀拼接 `subscriptions.<名称>.path`，客户端识别方式见[订阅与分流](#订阅与分流)。使用本轮选择的 `subscription`，在本机验证下载内容与准备的文件一致：

```sh
read -r -s -p '订阅的完整 HTTPS 地址：' subscription_url
printf '\n'
curl --fail --show-error "${subscription_url}?client=linux" \
  --output "tmp/vps/subscriptions/$subscription/downloaded-linux.json"
cmp "tmp/vps/subscriptions/$subscription/linux.json" \
  "tmp/vps/subscriptions/$subscription/downloaded-linux.json"
unset subscription_url
```

### 仅更新订阅

用途规则、默认出口、路径显示名、客户端 DNS、订阅名称或地址变化时，编辑对应的 inventory 或规则文件，完成[准备部署材料](#准备部署材料)，再按[发布订阅 Worker](#发布订阅-worker)发布并核对下载内容。随后[切换客户端](#切换客户端)，更新相应订阅或配置并确认用途选择，最后[清理部署材料](#清理部署材料)。涉及服务端认证和连接参数的变化，按[日常更新的范围](#日常更新的范围)安排节点部署。

## 初次部署

先完成[准备部署材料](#准备部署材料)和[部署 Workers](#部署-workers)。以下每次安装一台节点；`node` 使用 inventory 中的节点名，例如：

```sh
node=edge
```

### 确认 SSH 与安装参数

节点名用于系统主机名、出口关系和 Colmena 的 `--on` 选择；节点的 `sshHost` 指定维护机连接时使用的 SSH 别名。例如，`edge.sshHost: foo` 对应 `colmena ... --on edge` 经 `foo` 连接。维护机的 `identity.sops.yaml` 中，`ssh.hosts` 管理 `HostName`、`Port`、`User`、`IdentityFile` 和代理；本流程在其中声明 `User root`。填写方式见[身份示例](../data/secrets/identity.example.yaml)，身份发布与激活见[身份管理](secrets.md#gpgssh-与-git-身份)。已有可用定义可直接沿用。

```sh
ssh_host=$(jq -r --arg node "$node" '.nodes[$node].sshHost' tmp/vps/metadata.json)
ssh -G "$ssh_host" | rg '^(hostname|port|user|identityfile|proxycommand) '
ssh-add -L
```

节点的 `sshServer` 配置目标机的 OpenSSH 服务：`rootAuthorizedKeys` 填写 root 账号接受的公钥，`port` 定义 sshd 监听端口，省略时为 22。维护机 SSH 配置的 `Port` 是实际连接端口；存在端口映射时，两者可以不同。供应商救援系统使用临时地址、端口和登录凭据，在安装时单独设置。

确认节点的磁盘设备和 `uefi`。`disk` 填写正常启动环境中的系统盘名称，BIOS 下用于安装 GRUB；救援环境中的写入目标在安装时根据实际磁盘另行选择。例如，正常启动为 `/dev/vda`，救援环境中可能是 `/dev/vdb`。

安装后的系统采用 `eth0` 等顺序网卡名，默认公网接口为 `eth0`；多网卡机器按安装后名称填写 `interface`，它同时用于网络配置和代理转发。救援系统可能采用不同的网卡名。`dhcp: true` 使用供应商 DHCP；静态网络填写 `dhcp: false`、`addresses`、`gateway` 和所需的 `nameservers`。`address` 是代理客户端和其他节点使用的 IPv4 地址。当前实例范围为 x86_64，`swapMiB` 默认 1024。

镜像大小由系统闭包决定，并预留根分区空间；首次启动将根分区和 ext4 文件系统扩展到目标磁盘，再创建 swap 文件。UEFI 镜像为启动区预留 512 MiB，BIOS 使用 GRUB；两者保留五个启动代次。磁盘容量无需写入 inventory，写盘前确认目标盘能容纳生成的镜像。

在供应商控制台为该节点放行实际 SSH TCP 端口、TCP 443 和 UDP 20000–29999，并确认救援启动和控制台可用。节点间转发的说明见[入口、出口与端口](#入口出口与端口)。

### 构建系统

在维护机完成当前节点的 bootstrap 镜像和完整系统构建。镜像仅含基础系统和登录公钥，完整系统的运行凭据在后续部署时下发。

```sh
(
  set -e
  install -d -m 700 tmp/vps/images tmp/vps/systems
  nix build --impure --out-link "tmp/vps/images/$node" ".#vpsBootstrap.$node"
  nix build --impure --out-link "tmp/vps/systems/$node" ".#colmenaHive.toplevel.$node"
)
```

构建完成后，按[检查节点证书](#检查节点证书)确认当前节点能够取证，再开始安装。

### 启动救援系统

按[进入救援环境](#进入救援环境)中的 Oracle Cloud 或 Virtualizor 流程启动救援系统、安装工具并开启 SSH。救援 SSH 就绪后回到维护机，继续下面的连接与选盘步骤。bootstrap 镜像保留在维护机，通过 SSH 流式写入目标盘。

### 救援连接与目标磁盘

救援系统的 SSH 就绪后，回到维护机填写连接参数。以下以有权限写入目标盘的 root 用户为默认值，使用密码或键盘交互认证，密码由 SSH 在终端提示输入。需要代理时，在数组的目标地址之前加入 `-o 'ProxyCommand=…'`，填写维护机可用的完整代理命令。

首次连接时通过供应商控制台核对救援 SSH 指纹；本次记录保存在对应节点的安装目录。命令使用 Linux 救援系统中的 Bash、gzip、GNU coreutils 和 util-linux。

```sh
read -r -p '救援地址：' rescue_address
read -r -p '救援 SSH 端口 [22]：' rescue_port
rescue_port=${rescue_port:-22}
read -r -p '救援用户 [root]：' rescue_user
rescue_user=${rescue_user:-root}

install -d -m 700 tmp/vps/install
rescue_ssh=(
  -T -F /dev/null -p "$rescue_port"
  -o BatchMode=no
  -o PreferredAuthentications=keyboard-interactive,password
  -o StrictHostKeyChecking=ask
  -o GlobalKnownHostsFile=/dev/null
  -o "UserKnownHostsFile=$PWD/tmp/vps/install/$node.known_hosts"
  "$rescue_user@$rescue_address"
)

ssh "${rescue_ssh[@]}" 'bash -se' <<'RESCUE'
for tool in gzip dd head sha256sum blockdev lsblk swapon findmnt sync; do
  command -v "$tool"
done
dd --version
lsblk -b -p -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
swapon --show
findmnt -rn -o SOURCE,TARGET
RESCUE
```

`lsblk` 显示完整设备路径、容量与分区关系，`findmnt` 列出全部挂载。通过挂载到 `/` 的来源确认救援根文件系统所在设备。`swapon --show` 列出启用的 swap，无输出表示当前未启用 swap。

结合磁盘容量、型号与供应商控制台选择要重装的目标整盘，保留救援系统使用的磁盘。设备路径以本次救援环境的输出为准，在维护机输入：

```sh
read -r -p '救援环境中的目标整盘：' rescue_disk
```

### 压缩、写入与回读

在维护机压缩当前节点已构建的镜像，并显示传输前后的大小。本台部署完成前保留镜像构建链接和安装文件，传输重试时可复用压缩文件。

```sh
image=$(realpath -e "tmp/vps/images/$node/nixos.img")
compressed="$PWD/tmp/vps/install/$node.img.gz"
(
  set -euo pipefail
  umask 077
  trap 'rm -f -- "$compressed.partial"' EXIT
  gzip -n -6 -c -- "$image" > "$compressed.partial"
  mv -- "$compressed.partial" "$compressed"
  ls -lh -- "$image" "$compressed"
)
```

**写盘会覆盖目标磁盘。** 保存所需数据并确认恢复方式，核对 `rescue_disk` 与容量。目标盘的所有分区应处于未挂载状态，该盘上的 swap 应已停用；确认后执行下面的写入与校验。远端流式解压，内存只需少量缓冲。

```sh
(
  set -euo pipefail
  image_bytes=$(stat -Lc '%s' "$image")
  local_sum=$(sha256sum -- "$image")
  local_hash=${local_sum%% *}
  printf '目标盘：%s\n镜像字节数：%s\n镜像 SHA-256：%s\n' \
    "$rescue_disk" "$image_bytes" "$local_hash"

  printf -v disk_command 'test -b %q && blockdev --getsize64 %q' \
    "$rescue_disk" "$rescue_disk"
  disk_bytes=$(ssh "${rescue_ssh[@]}" "$disk_command")
  if (( disk_bytes < image_bytes )); then
    printf '目标盘容量不足：%s bytes\n' "$disk_bytes" >&2
    exit 1
  fi

  printf -v write_command \
    'gzip -dc | dd of=%q bs=4M iflag=fullblock conv=fsync status=progress' \
    "$rescue_disk"
  printf -v write_command 'bash -o pipefail -c %q' "$write_command"
  ssh "${rescue_ssh[@]}" "$write_command" < "$compressed"

  printf -v verify_command 'bash -se -- %q %q' "$rescue_disk" "$image_bytes"
  remote_sum=$(ssh "${rescue_ssh[@]}" "$verify_command" <<'RESCUE'
set -o pipefail
sync
blockdev --flushbufs "$1"
head -c "$2" -- "$1" | sha256sum
RESCUE
  )
  remote_hash=${remote_sum%% *}
  printf '磁盘回读 SHA-256：%s\n' "$remote_hash"
  if [[ "$local_hash" != "$remote_hash" ]]; then
    printf '校验失败，保持救援环境。\n' >&2
    exit 1
  fi
  printf '校验通过，可以从系统盘启动。\n'
)
```

回读只计算目标盘开头与原始镜像等长的内容，在远端完成哈希计算。解压、写入或回读失败时命令返回错误；保持救援环境，排除原因后重新执行完整的写入与校验。

### 首次启动与部署

校验通过后，将供应商启动方式设为清单中的 BIOS 或 UEFI，退出救援模式并从系统盘重启。可在供应商控制台重启，也可在设置好启动方式后执行：

```sh
ssh "${rescue_ssh[@]}" reboot
```

首次启动在目标机生成 SSH host key，其指纹写入 journal 和控制台。通过供应商控制台核对指纹后，把主机加入维护机的 `known_hosts`。如果控制台无法显示启动输出，可在启动过一次后回到救援系统，只读挂载根分区，用 `ssh-keygen -lf <挂载点>/etc/ssh/ssh_host_ed25519_key.pub` 核对。后续部署、重启和回滚保留该身份。

首次连接使用普通 SSH，在接受提示前比对指纹。重装后若已有记录不匹配，先核对控制台，再用 `ssh-keygen -R '地址'` 清除该条旧记录；非默认端口使用 `ssh-keygen -R '[地址]:端口'`。

```sh
ssh_host=$(jq -r --arg node "$node" '.nodes[$node].sshHost' tmp/vps/metadata.json)
ssh "$ssh_host" 'df -h /; swapon --show; ip -4 address; resolvectl status'
colmena apply test --impure --on "$node" --parallel 1 --no-substitute
ssh "$ssh_host" 'systemctl is-active site-vps-proxy.service haproxy.service'
```

按[验证代理请求](#验证代理请求)确认本台入口、出口的 Trojan 和 HY2 路径。随后保存为默认启动代次，并确认重启后的服务：

```sh
colmena apply switch --impure --on "$node" --parallel 1 --no-substitute
ssh "$ssh_host" 'systemctl reboot'
```

等待 SSH 恢复后，在维护机确认服务：

```sh
ssh "$ssh_host" 'systemctl is-active site-vps-proxy.service haproxy.service'
```

安装下一台时修改 `node`，从[初次部署](#初次部署)开始重复操作，使用该台的救援连接参数和目标磁盘；本轮生成的部署材料继续共用。已上线节点按[验证多个节点](#验证多个节点)检查跨节点路径。部署异常时按[回退系统](#回退系统)恢复。

## 更新已有 VPS

已运行本项目完整系统的 VPS 使用 Colmena 更新。每台依次完成部署、重启和请求验证，再处理下一台。维护机的代理与 SSH 连接应使用本轮正在重启的节点之外的可用路径。

### 日常更新的范围

根据变化选择部署对象；仅涉及客户端内容时，使用[仅更新订阅](#仅更新订阅)流程。

| 变化 | 应用步骤 |
| --- | --- |
| 用途规则、默认出口、路径显示名、客户端 DNS | 重新生成并发布订阅 Worker，客户端更新对应订阅或配置 |
| 订阅地址或名称 | 发布订阅 Worker，使用新地址或更新客户端备注/配置 |
| 订阅密钥、授权出口、撤销订阅 | 部署并重启涉及的 VPS，使认证配置生效，再发布订阅 Worker 并更新客户端 |
| 节点入口、出口承载或上游连接参数 | 部署、重启并验证涉及的 VPS；路径或客户端参数变化时同步发布订阅 |
| 系统模块、SSH 服务端设置、VPS 包集 | 对受影响节点执行 `boot`，重启后验证运行系统与服务 |
| `sshHost` 或维护机的 SSH 配置 | 更新 Colmena 的连接选择与维护机 SSH 配置 |
| 证书 Worker 凭据或访问令牌 | 先发布证书 Worker 并验证取证；令牌变化时部署并重启对应节点 |

更换订阅密钥时，服务端与客户端在同一维护窗口更新。发布包含新认证参数的订阅前，先确认有关节点已经启用对应配置。

### 准备本轮更新

节点和订阅声明写入 inventory；系统模块直接编辑仓库中的对应文件，依赖升级见[更新 VPS 包集](#更新-vps-包集)。编辑完成后，按[准备部署材料](#准备部署材料)生成当前代码与 inventory 对应的文件。证书 Worker 或其凭据有变化时，先[发布证书 Worker](#发布证书-worker)并检查相关节点取证。

在维护机选择当前要更新的节点，`subscription` 沿用本轮准备时选择的订阅：

```sh
node=edge
```

### 部署与重启

`node` 是 Colmena 的节点选择；实际连接使用该节点的 `sshHost`，地址、端口、用户和密钥来自维护机的 SSH 配置。部署前连接并记录当前运行系统路径、启动默认代次和代次列表，供[回退系统](#回退系统)时选择：

```sh
ssh_host=$(jq -r --arg node "$node" '.nodes[$node].sshHost' tmp/vps/metadata.json)
ssh "$ssh_host" '
  readlink -f /run/current-system
  readlink /nix/var/nix/profiles/system
  nix-env -p /nix/var/nix/profiles/system --list-generations
'
```

执行部署并记录下次启动的系统路径：

```sh
colmena apply boot --impure --on "$node" --parallel 1 --no-substitute &&
expected_system=$(ssh "$ssh_host" 'readlink -f /nix/var/nix/profiles/system') &&
printf '下次启动系统：%s\n' "$expected_system"
```

Colmena 在维护机构建完整系统，通过 SSH 复制系统闭包和本节点凭据，并设置启动默认代次。`--no-substitute` 使复制阶段由维护机提供闭包；维护机构建仍使用自己的缓存配置。`boot` 完成后，当前服务继续使用原配置，新系统在下次启动时启用。

在选定的维护时机重启该节点：

```sh
ssh "$ssh_host" 'systemctl reboot'
```

等待 SSH 恢复后，在维护机的同一 shell 中确认运行系统与刚才记录的路径一致，并检查服务。若本轮修改了 SSH 端口、地址或登录密钥，重连使用新参数，保留原参数供回退使用。

```sh
running_system=$(ssh "$ssh_host" 'readlink -f /run/current-system')
printf '预期系统：%s\n运行系统：%s\n' "$expected_system" "$running_system"
test "$running_system" = "$expected_system" &&
ssh "$ssh_host" 'systemctl is-active site-vps-proxy.service haproxy.service'
```

按[验证代理请求](#验证代理请求)检查该节点的 Trojan、HY2 和受影响的跨节点路径。完成后可设置 `node=west`，从本节的 SSH 连接与代次记录开始处理下一台，继续使用本轮生成的材料。

需要同步客户端参数时，在有关节点重启、验证完成后[发布订阅 Worker](#发布订阅-worker)，再[切换客户端](#切换客户端)。本轮部署与发布全部完成后[清理部署材料](#清理部署材料)。

需要立即试运行时，Colmena 的 `test` 目标会启用新配置并保留原启动默认代次，随后可直接执行代理验证；`switch` 同时启用新配置并设置启动默认代次。目标含义见 [Colmena 命令说明](https://colmena.cli.rs/unstable/reference/cli.html#colmena-apply)。

### 更新 VPS 包集

```sh
nix flake update nixpkgs-remote
```

VPS 与 laptop 分别跟踪 nixos-unstable；上面的命令只推进 VPS 的锁定版本。验证使用公开合成节点，从实际 bootstrap 镜像启动，覆盖低内存安装和 Colmena 部署；真实节点仍在维护机单独构建。具体命令见[验证指南](validation.md)，定时更新和合并条件见[CI](ci.md#入口和候选提交)。

### 回退系统

通过维护机的 SSH 别名连接目标 VPS；连接不可用时，通过供应商控制台选择旧启动项。以下命令在目标 VPS 的 root shell 中执行：

```sh
nix-env -p /nix/var/nix/profiles/system --list-generations
```

将 `generation` 设置为更新前记录的代次编号，确认其系统路径与记录一致：

```sh
generation=42
readlink -f "/nix/var/nix/profiles/system-${generation}-link"
```

选择该代次作为启动默认值并更新启动项：

```sh
nix-env -p /nix/var/nix/profiles/system --switch-generation "$generation" &&
/nix/var/nix/profiles/system/bin/switch-to-configuration boot
```

成功后，若当前已经运行新系统，重启进入所选代次：

```sh
systemctl reboot
```

若只是取消尚未重启的更新，设置回原启动默认值即可。仅执行过 `test` 时，原启动默认代次保持不变，可重启恢复。重新连接后确认运行系统路径、服务和代理请求。

旧凭据目录和证书对保留，供旧代次使用。清理旧系统代次后，再删除已确认没有系统引用的旧凭据目录。应用数据和运行凭据还需按各自恢复要求备份；系统重建不能代替数据恢复。

## 验证多个节点

每台完成部署、重启和服务确认后，先验证自身承载的出口，再验证已上线节点之间的转发。下面的探测命令同时适用于单台安装后的检查和多节点验证。

### 验证代理请求

在维护机的 `vps` 开发环境中执行，`subscription` 使用本轮选择的订阅。先列出 provider 中的路径名称：

```sh
provider="tmp/vps/subscriptions/$subscription/linux.json"
jq -r '.outbounds[].tag' "$provider"
```

将 `probe_path` 设为要验证的完整路径。首次安装时先选当前节点自身承载的出口，下例使用示例 inventory 的原生出口：

```sh
probe_path="${node} · native · Trojan"
```

为所选路径生成探测配置并启动 sing-box：

```sh
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

在另一个终端发出实际请求，确认返回的 `ip` 属于选中的出口：

```sh
curl --fail --show-error --max-time 20 \
  --socks5-hostname 127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace
```

用 Ctrl-C 停下探测。验证下一条路径时，重新设置 `probe_path`，从生成探测配置开始重复操作；使用 `HY2` 路径可验证 UDP 入口。

### 本机入口与跨节点路径

以已上线的 `edge`、`west` 及各自原生出口为例，依次将 `probe_path` 设为下表中的完整名称，分别执行[验证代理请求](#验证代理请求)。实际名称以 provider 的列表为准：

| 入口与承载 VPS | Trojan 路径 | HY2 路径 |
| --- | --- | --- |
| edge 自身 | `edge · native · Trojan` | `edge · native · HY2` |
| west 自身 | `west · native · Trojan` | `west · native · HY2` |
| edge 入口、west 承载 | `edge → west · native · Trojan` | `edge → west · native · HY2` |
| west 入口、edge 承载 | `west → edge · native · Trojan` | `west → edge · native · HY2` |

每条路径都应完成 HTTPS 请求，返回的出口 IP 应属于承载 VPS 的原生网络。验证上游出口时，从列表选择带 `[出口标识]` 的对应路径，按同样方式核对上游出口 IP。增加节点时，继续检查该节点自身及本轮涉及的两个方向的跨节点路径。

### 切换客户端

相关路径通过验证后，确认[订阅 Worker](#发布订阅-worker)已发布本轮文件，并完成下载核对，再更新客户端。

官方 sing-box 可直接导入完整 URL；Shadowrocket 可导入[完整配置或分开的节点订阅与分流配置](#shadowrocket-导入)。laptop 使用下载的 Linux provider，按[用途出口](network.md#用途出口)保存并执行 `network-policy check`、`network-policy apply`。在客户端确认用途所选的逻辑出口及其自动路径组；旧订阅保留到实际使用稳定后再撤下。

### 清理部署材料

本轮 VPS 部署和 Worker 发布全部完成、手动代理探测停止后，在仓库根目录删除部署材料及探测配置。Wrangler 登录状态独立保留，后续可直接重新准备和发布；需要撤销维护机登录时运行 `wrangler logout`。

```sh
rm -r -- tmp/vps
rm -f -- tmp/devtools/network/vps-probe.json
```

## 进入救援环境

救援系统需要 root 权限、SSH、Bash、gzip、GNU coreutils 和 util-linux。按供应商选择下面的启动方式，SSH 就绪后返回[救援连接与目标磁盘](#救援连接与目标磁盘)，在维护机继续安装。

### Oracle Cloud：netboot.xyz 与 Tiny Core

以下用于 x86_64 UEFI 实例，对应 inventory 中的 `uefi: true`。

原系统仍可通过 SSH 登录时，将 [netboot.xyz 的 x86_64 EFI 启动文件](https://netboot.xyz/downloads/) 放入 EFI 系统分区。已有该文件时可直接使用。以原 NixOS 的 EFI 分区挂载在 `/boot` 为例，在原 VPS 的 root shell 中执行：

```sh
install -d /boot/EFI/netboot
curl --fail --location https://boot.netboot.xyz/ipxe/netboot.xyz.efi \
  --output /boot/EFI/netboot/netboot.xyz.efi
sync
```

在 OCI 实例页面打开 **Console connection → Launch Cloud Shell connection**，连接实例的[串口控制台](https://docs.oracle.com/en-us/iaas/Content/Compute/References/serialconsole.htm)。保持串口连接，在 OCI 控制台重启实例，启动时连续按 `Esc` 进入 UEFI 菜单。从 **Boot Maintenance Manager → Boot From File** 选择 EFI 分区中的 `EFI/netboot/netboot.xyz.efi`。

进入 netboot.xyz 后，先选择 **iPXE shell**，输入：

```text
set cmdline console=ttyS0,115200n8 noswap norestore rdinit=/bin/sh -- -i
exit
```

按所示顺序设置参数，`noswap norestore` 位于 `rdinit` 之前，`-- -i` 传给早期 shell。`noswap` 停用磁盘 swap，保留内存中的 zram。返回菜单后依次选择 **Live CDs → Tiny Core Linux → x86_64 → CorePure**。

出现早期 root shell 后，在串口窗口执行：

```sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
printf '\nttyS0::respawn:/bin/sh\n' >> /etc/inittab
exec /init
```

这会为 `ttyS0` 添加 shell，再将 PID 1 交给 Tiny Core 的正常启动流程。等初始化完成、串口再次出现提示符后，安装 SSH 和写盘依赖：

```sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
su - tc -c 'tce-load -wi openssh bash coreutils util-linux gzip'
passwd root
touch /etc/sysconfig/superuser
```

`tce-load` 以 Tiny Core 的 `tc` 用户安装扩展；`superuser` 文件使 root 登录保持为 root。接着在同一串口 root shell 中配置本次救援的密码登录，并让 SSH 命令优先使用刚安装的工具：

```sh
cat > /tmp/rescue-sshd_config <<'EOF'
Port 22
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
AllowUsers root
SetEnv PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Subsystem sftp internal-sftp
EOF
mv /tmp/rescue-sshd_config /usr/local/etc/ssh/sshd_config
/usr/local/etc/init.d/openssh start

for key in /usr/local/etc/ssh/ssh_host_*_key.pub; do
  ssh-keygen -lf "$key"
done
```

在 OCI 的 Security List 或 NSG 放行维护机来源的 TCP 22。返回[救援连接与目标磁盘](#救援连接与目标磁盘)，救援地址填写实例公网 IP，用户为 `root`，使用刚设置的密码，并与串口显示的 SSH 指纹比对。Tiny Core 的配置和依赖保存在内存中，本次启动结束即释放。

### Virtualizor：Rescue Mode

在 VPS 面板的 [Rescue Mode](https://www.virtualizor.com/docs/enduser/rescue-mode) 页面设置临时 root 密码，启用救援模式。面板会重启 VPS 并启动带 SSH 的救援系统；使用面板提供的地址、端口和该密码连接。返回[救援连接与目标磁盘](#救援连接与目标磁盘)确认工具与目标盘；完成写入和回读校验后，在面板关闭 Rescue Mode，再从系统盘启动。

## 系统与部署模型

VPS 使用独立锁定的 `nixpkgs-remote` 和轻量 profile：持久 ext4 根分区、首次启动扩容、磁盘 swap、SSH 公钥登录。BIOS 和 UEFI 由 inventory 的 `uefi` 选择。构建在维护机完成，Colmena 通过 SSH 部署系统与凭据，适合内存较小的 VPS。

VPS 的状态随根磁盘保留。这里采用普通持久系统，便于保留 SSH host key、服务数据、证书和可回滚的凭据。应用使用原生 NixOS 模块；每个节点的 `modules` 数组列出仓库相对路径，为完整系统组合不同服务。网络、磁盘和 SSH 服务端来自同一份基础配置，bootstrap 与完整系统共用。

完整系统提供 Vim、Screen，以及文件传输、网络诊断和进程排查工具，清单见[维护工具配置](../profiles/vps/tools.nix)。Vim 是默认编辑器；交互 shell 提供 `ll`、`la` 和 `..`。这些工具在 Colmena 部署完整系统时安装，bootstrap 保持精简。

### Docker

需要容器的节点在 `modules` 中加入 `modules/vps/docker.nix`。Docker 随系统启动，容器数据保存在 `/var/lib/docker`。系统防火墙允许 `docker0` 和默认命名为 `br-*` 的自定义 bridge 转发；Docker 管理容器 NAT、隔离和端口发布，同时保留 VPS 节点间的代理转发。

容器使用 Docker 原生 DNS：默认 bridge 使用宿主上游解析器地址，自定义 bridge 使用 Docker 内置解析器，并支持同一网络内的容器名。容器向上游发送普通 DNS 查询；VPS 宿主自身仍使用严格 DoT。应用可通过 Docker 的 `--dns` 或 Compose 的 `dns` 设置指定解析器。

## 撤销订阅

更换订阅地址时生成新的 UUID，更新 `path` 并重新发布订阅 Worker，再把新地址交给使用者。撤销整份订阅时删除对应条目，按[更新已有 VPS](#更新已有-vps)使相关节点的新认证配置生效，再发布订阅 Worker，使已有代理凭据和下载入口均失效。

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

`subscriptions` 声明独立的订阅，例如 `primary`、`guest`，同一订阅可供多个客户端使用。可选的 `name` 是客户端显示名，省略时使用订阅键名。`exits` 决定授权的逻辑出口，`entries` 决定可选入口，`groups` 把站点用途绑定到出口。

完整路径为“入口 × 承载 VPS × 出口 × 协议”。所有客户端共用以下命名：

| 路径 | 含义 |
| --- | --- |
| `edge → west · [us] · Trojan` | 连接 edge 的 TCP 443，由 west 解密，再从 `us` 上游发出 |
| `edge → west · native · HY2` | 连接 edge 的 Hysteria2 入口，由 west 解密并使用原生网络出站 |
| `west · native · Trojan` | 直接连接 west，由 west 原生网络出站 |

入口与承载 VPS 相同时只显示一次。类型为 `native`、标识为 `<承载 VPS>-native` 的出口显示为 `native`，其他出口显示为 `[出口标识]`，便于区分同机承载的多个出口。首次获得新路径名称后，原先固定的路径需要重新选择。

每份订阅的 `key` 通过 HMAC-SHA256 为各出口、各协议派生密码；同一出口的所有承载 VPS 使用相同订阅身份。VPS 只收到自身承载的身份和上游凭据。调整入口、承载 VPS、订阅名称、订阅路径或用途选择时，已有密码保持稳定；更换密钥或出口标识会改变密码。

选择分为两层：

| 选择位置 | 作用 | 示例 |
| --- | --- | --- |
| 用途组，如 `cryptocurrency` | 选择逻辑出口 | 从 `us` 切到 `uk` |
| `exit-us` | 自动选择或固定一条完整路径 | `exit-us-auto`，或 `edge → west · [us] · Trojan` |

用途组的 `exits` 是可选出口，`default` 是初始选择；多出口组明确填写，单出口组可省略。客户端已保存的有效选择优先。多个用途选中同一个出口时，共享该出口的路径选择；例如 `hideme` 和 `cryptocurrency` 都使用 `us`，固定 `exit-us` 的路径会同时影响这两个用途。

自动组通过各条完整路径请求测试 URL，在可用路径中选择延迟较低者。sing-box 的探测间隔为三分钟，切换容差为 100 毫秒；Shadowrocket 的探测间隔为十分钟、超时为五秒，切换容差为零。测量覆盖入口连接、跨 VPS 转发和上游出站。入口或承载 VPS 故障后，后续探测将新连接移到仍可用的路径；探测间隔、连接超时和应用重连会影响实际恢复时间。健康的现有连接继续使用原路径，已断开的连接由应用重建。

排障时，在 `exit-us` 中固定具体路径，便可单独观察某个入口、承载 VPS 和协议。固定路径失效时仍保留这一选择，恢复自动切换需要重新选择 `exit-us-auto`。逻辑出口之间的切换由用户决定，例如全部 `us` 路径不可用时，可将用途改为 `uk`。

增加出口时，在顶层 `exits` 声明出站方式和承载 VPS，将名称加入订阅的 `exits`，再加入相应用途组。涉及的 VPS 启用新配置并完成请求验证后，发布订阅，客户端获得新的路径。

更换订阅 `key` 会同时更换该订阅所有出口、所有协议的密码。准备新部署材料后，按[更新已有 VPS](#更新已有-vps)使有关节点启用新配置，再发布订阅 Worker，最后让客户端更新订阅；期间旧客户端会暂时无法连接。订阅地址可以保持原值。

Linux provider、官方移动 sing-box 和 Shadowrocket 共用这些关系和用途顺序。各客户端使用自己的原生远程规则格式及更新机制；规则来源和覆盖范围因此可能有差异。laptop 的接入与持久选择见[用途出口](network.md#用途出口)。VPS 的 `native` 指远端 VPS 原生网络，客户端 `direct` 指客户端自己的网络。

每份订阅的 `path` 为 `/<随机 UUID>`，拼接在 Cloudflare Worker 路由前缀之后。例如控制台 Route 为 `https://example.com/<worker-route-uuid>*`，则订阅地址为 `https://example.com/<worker-route-uuid><subscriptions.path>`。路由前缀由 Cloudflare 控制台维护，订阅路径在 inventory 中管理。

Worker 根据官方 sing-box 或 Shadowrocket 的 UA 选择内容，也可通过 `?client=` 显式选择，参数优先：

| 参数 | 返回内容 |
| --- | --- |
| `?client=linux` | 本项目使用的 provider |
| `?client=sing-box` | 官方 sing-box 完整配置 |
| `?client=shadowrocket` | Shadowrocket 完整配置，包含节点、DNS、用途规则和出口组 |
| `?client=shadowrocket-subscribe` | Shadowrocket 节点订阅 |
| `?client=shadowrocket-config` | Shadowrocket 分流配置，通过订阅名称引用节点 |

UA 无法识别时返回 400，提示指定 `client`。本项目下载 provider 时使用 `?client=linux`。Worker 通过 HTTPS 提供内容；完整订阅地址是访问凭据，应保存在私密位置。响应使用 `private, no-store`，Worker 访问日志保持关闭。

### Shadowrocket 导入

在配置页导入并启用 `?client=shadowrocket`，即可使用包含节点的完整配置；省略参数且 UA 识别为 Shadowrocket 时返回相同内容。节点、DNS、用途规则和出口组随配置一起更新。

也可在首页导入 `?client=shadowrocket-subscribe` 节点订阅，再在配置页导入 `?client=shadowrocket-config` 分流配置。节点订阅保存连接地址、协议、认证信息和路径名；分流配置保存 DNS、用途规则及出口组。出口组通过 `name` 引用订阅，并按完整路径名筛选成员。两种导入方式都支持自动选择和固定路径。

准备材料后，在维护机生成导入链接，选择完整配置或分开导入。`subscription` 使用前面选择的订阅键名；提示输入的地址是 Cloudflare 路由前缀拼接订阅 UUID 的完整 HTTPS 地址：

```sh
python3 - "$subscription" <<'PY'
import base64
import getpass
import json
from pathlib import Path
import sys
from urllib.parse import quote

metadata = json.loads((Path("tmp/vps/subscriptions") / sys.argv[1] / "metadata.json").read_text())
url = getpass.getpass("订阅的完整 HTTPS 地址：").strip()
print("完整配置（含节点）：")
print(f"shadowrocket://config/add/{url}?client=shadowrocket")
nodes = base64.b64encode((url + "?client=shadowrocket-subscribe").encode()).decode()
print("节点订阅：")
print(f"shadowrocket://add/sub://{nodes}?remark={quote(metadata['name'], safe='')}")
print("分流配置：")
print(f"shadowrocket://config/add/{url}?client=shadowrocket-config")
PY
```

节点导入链接带入订阅显示名，配置下载使用 `<name>.conf` 文件名。通过 HTTPS 地址手动添加节点订阅时，将备注填写为相同的 `name`；配置中的订阅引用按这个名称查找节点。

采用分开导入时，连接地址或密码调整后更新首页订阅；DNS、用途规则或组设置调整后更新配置。入口、承载 VPS 或逻辑出口变化时，发布 Worker 后更新两者。修改显示名后同步修改首页订阅备注并更新配置。

远程规则来源变化时，更新当前启用的配置并下载其引用的规则集，再从连接记录核对命中的规则与出口。

## 规则与 DNS

订阅的用途组决定匹配之后使用哪个出口，例如 `groups.cryptocurrency` 决定加密货币服务使用 `us` 还是其他出口。`proxy` 为必需组，用于通用海外规则和未绑定的可选用途，`hideme` 用于隐私站点及最终兜底；示例明确绑定两者。分类、顺序和重叠规则的行为统一在[网络用途出口](network.md#用途出口)说明。

移动客户端的基础配置分别位于 [sing-box-client.json](../data/network/sing-box-client.json) 和 [shadowrocket-client.conf](../data/network/shadowrocket-client.conf)。生成器插入订阅授权的路径及用途规则；远程规则的内容由客户端原生机制更新。Linux 的用途分类也读取同一目录，应用方式见[网络规则来源](network.md#规则来源与更新)。

客户端的直连解析器统一声明在 [direct-dns.toml](../data/network/direct-dns.toml)，包含 DNSPod 和阿里 DNS 各自的 DoH、DoT。生成配置时读取这份声明，解析器使用固定 IP 并校验 TLS 证书，建立连接时无需引导 DNS。

订阅 sing-box 使用 1.14 起提供的原生 DNS 竞速：直连查询未命中缓存时并发询问四路，最先返回的 NOERROR（包括 NODATA）或 NXDOMAIN 胜出。单路错误留给其他分支继续处理，等待预算为 4 秒，全部失败返回 SERVFAIL。竞速位于共同策略中对应 direct 规则的位置，较早命中的用途仍使用该用途的解析出口。直接连接的域名也先通过 DNS 策略解析，再连接解析地址；本地域名使用专用解析路径。

Shadowrocket 使用同一声明中的两个 DoH 作为主解析、两个 DoT 作为备用解析，由客户端原生机制调度。直连域名使用同一解析配置。

修改直连解析器后，laptop 切换系统配置；移动端重新生成并发布 subscriptions Worker，再更新客户端配置。VPS 服务端的解析器由下面的系统和逻辑出口配置管理。

VPS 有两种 DNS 用途：

- 系统 DNS 供系统服务、证书获取、时钟服务和上游服务器域名解析使用。systemd-resolved 通过严格 DoT 查询，按 TTL 缓存；当前解析器不可用时切换到另一台，恢复后继续使用当前可用服务器。`nodes.*.nameservers` 可用 `IP#TLS证书名` 覆盖默认列表。DHCP 与 RA 负责网络配置，解析器由清单指定。
- 代理目标的 DNS 经选中的逻辑出口发送。默认列表在 [vps-dns.json](../data/network/vps-dns.json)，`exits.*.dns` 可用原生 DNS server 数组覆盖。sing-box 并发查询各解析器，首先返回的正常应答或 NXDOMAIN 完成本次查询；SERVFAIL、拒绝和连接错误留给其他解析器继续处理，全部失败则返回失败。各出口使用各自的解析器实例及缓存。

例如，客户端将 `foo.example` 经 `edge → west · [us] · Trojan` 发送：edge 转发 TLS 到 west；west 根据认证身份选择 `us`，从 `us` 查询目标 DNS，再从 `us` 连接解析结果。系统 DNS 只负责必要的基础设施域名，代理目标的解析与流量采用同一出口。

```sh
resolvectl status
resolvectl query example.com
journalctl -b -u systemd-resolved -u site-vps-proxy
```

时间同步配置与排查命令见 [chrony NTS](network.md#时间同步)。

## 证书更新

`workers.certificates.url` 填写证书 Worker 路由去掉末尾 `*` 的完整 HTTPS 基地址；节点名称会追加在该地址之后，例如 `https://example.com/<certificate-route-uuid>/edge`。

证书 Worker 从 Porkbun 获取声明域名的证书和私钥，节点通过自己的 bearer token 获取。每台 VPS 首次启用时获取一次，此后每日带随机延迟检查；证书链、域名、剩余有效期和密钥匹配全部通过后，原子切换整对证书并重启使用它的服务。下载或验证失败时继续使用现有证书。状态保存在 `/var/lib/site-vps-certificate/`。

同一通配符证书的私钥由使用它的 VPS 共享；任一这些节点失陷都需要按这个信任范围轮换证书。Porkbun API 凭据只存在证书 Worker 的 secret binding 中，节点仅持有取证 token。
