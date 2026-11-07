# laptop2 首次部署与恢复

在原系统中手动执行本文，用户为 `ubuntu`、UID 1000，持久根为 `/persist`，仓库已经使用根目录的新配置。每节逐块执行，遇到错误先停止并核对；涉及个人文件的命令只在 laptop2 本机运行。

现有分区、LUKS、Btrfs 子卷、swap、Secure Boot 身份及系统和 Home Manager 的 `stateVersion` 沿用原值。这里使用 `nixos-rebuild boot` 安装启动代次。分区布局由现有声明描述，部署不运行磁盘格式化命令。

## 已部署系统的日常升级

完成首次部署的机器使用下面的流程。仓库中的新文件需要先纳入 Git，构建才会读取；依赖保持 `flake.lock` 中的版本。

```sh
cd /home/ubuntu/dev/workspace/nixos-config
git status --short
nix build --no-link --no-update-lock-file .#nixosConfigurations.laptop2.config.system.build.toplevel
sudo nixos-rebuild boot --flake .#laptop2 --no-update-lock-file
sudo bootctl list
```

核对新代次与上一可启动代次均在列表中，保存工作并正常退出应用，再重启。`boot` 安装下次启动所用的系统，不在当前桌面中切换会话服务。启动后确认 Breeze 磁盘解锁、精简 Breeze 的 SDDM 登录、Kitty 的 JetBrainsMono Nerd Font 12 pt 和 Rofi 16 pt；分别用电源菜单注销到 SDDM 并切换 Sway/i3/Plasma，测试手动和空闲锁屏，在新会话播放音频并录音。Sway/i3 应先恢复本地壁纸，注销和重启后保留当前图片及下载到期时间；下载期间或失败时画面继续可用。

```sh
nixos-version
readlink -e /run/booted-system
sudo sbctl status
systemctl --failed --no-pager
systemctl --user --failed --no-pager
systemctl --user show pipewire.service pipewire-pulse.service wireplumber.service \
  -p Id -p ActiveState -p Result -p NRestarts
journalctl -b COREDUMP_COMM=pipewire --no-pager
```

若新代次不能正常使用，在启动菜单选择上一代次。Plymouth 页面按 Esc 可查看启动详情。保留上一代次直到磁盘解锁、三种会话、锁屏和音频验收完成；日常升级不需要重新执行本文后续的首次迁移操作。

## 恢复基线

2026-11-05 的实机核对结果：

| 项目 | 已核对值 |
| --- | --- |
| 运行、启动及 system profile | 同为 generation 1278，NixOS `26.11.20261023.3ec6363` |
| 系统产物 | `/nix/store/fhyw4fq24wgg5xi42fwrw2qmx424j3n3-nixos-system-laptop2-26.11.20261023.3ec6363` |
| 实际源码 | `/nix/store/pikkfy1alzjki5qnzr8010a42qg95hqa-source` |
| 实际 Home Manager | `/nix/store/5gxglm17i7lz8j06v12v0sqpsvnhhpym-home-manager-generation` |
| 原 Git HEAD | `d9c100c08ed45f7bc8c6a02c2528a687c076bb2e`；运行源码包含未提交的 VirtualBox 修改 |
| 源码比对 | 替换前的工作树仅 `.gitignore` 与实际构建源码不同；两份 `flake.lock` 相同 |
| 存储 | `/` 为 16 GiB tmpfs，`/tmp` 为 80% 内存上限；`/persist` 与 `/nix` 位于 crypt0 的同一 Btrfs 文件系统 |
| Docker | 29.9.1，Btrfs，`/var/lib/docker`，`live-restore=true`；数据均可重建 |

在原系统重新核对下面的输出，再固定对应产物。执行时若已经升级，按实际运行的代次重新确定恢复基线。

```sh
cd /home/ubuntu/dev/workspace/nixos-config
nixos-version --json
readlink -e /run/current-system
readlink -e /run/booted-system
readlink -e /nix/var/nix/profiles/system
readlink -e /etc/flake-inputs/self
readlink -e "$HOME/.local/state/home-manager/gcroots/current-home"
systemctl show home-manager-ubuntu.service -p ExecStart --no-pager
sudo nix-env --profile /nix/var/nix/profiles/system --list-generations
sudo bootctl list
```

确认 Home Manager 的 GC root 与激活单元中的 generation 一致。恢复目录使用一个尚未存在的名称；本文各阶段均使用同一个路径：

```sh
umask 077
recovery=/persist/home/ubuntu/migration-1278
mkdir -m 0700 "$recovery"
old_system=$(readlink -e /run/current-system)
old_home=$(readlink -e "$HOME/.local/state/home-manager/gcroots/current-home")
old_source=$(readlink -e /etc/flake-inputs/self)
printf '%s\n' "$old_system" > "$recovery/system-path"
printf '%s\n' "$old_home" > "$recovery/home-path"
printf '%s\n' "$old_source" > "$recovery/source-path"
sudo mkdir -m 0755 /nix/var/nix/gcroots/laptop2-before-migration
sudo ln -s "$old_system" /nix/var/nix/gcroots/laptop2-before-migration/system
sudo ln -s "$old_home" /nix/var/nix/gcroots/laptop2-before-migration/home
sudo ln -s "$old_source" /nix/var/nix/gcroots/laptop2-before-migration/source
mkdir "$recovery/source"
cp -a -- "$old_source/." "$recovery/source/"
git rev-parse HEAD > "$recovery/checkout-head"
git diff --binary > "$recovery/checkout-diff.patch"
sudo bootctl list > "$recovery/boot-entries.txt"
sudo tar -C /boot -cpf "$recovery/esp.tar" .
sudo cp -a -- /persist/etc/secureboot "$recovery/secureboot"
sudo cp -a -- /persist/var/lib/sops-nix/keys.txt "$recovery/age-keys.txt"
sudo chmod 0600 "$recovery/esp.tar" "$recovery/age-keys.txt"
sudo tar -tf "$recovery/esp.tar" > "$recovery/esp-files.txt"
sudo stat -c '%a %u:%g %n' /persist/home/ubuntu /persist/etc/secureboot \
  /persist/var/lib/sops-nix /persist/var/lib/private/tailscale \
  > "$recovery/directory-modes.txt"
```

GC roots 保留 store 产物；启动菜单还依赖 system generation 链接和 ESP 中的文件。部署前后都核对 1278 的条目，迁移验收期间保留该 generation。正常每周 GC 的 30 天策略继续使用。

恢复材料放在同一持久盘，用于这次部署回退；同时备好现有 LUKS 解锁方式、可启动的 NixOS 安装介质和离线凭据。`sbctl status` 的旧配置格式提示不要求本次迁移密钥；沿用 `/etc/secureboot/keys/db/` 的现有签名材料。

## 准备凭据

目标配置使用三份 SOPS YAML，原配置与原密文保留供回退。

### 准备私密工作目录

在新项目的仓库根目录进入开发 shell。以下明文仅在本机查看，编辑器关闭自动同步、云端插件和备份文件；退出本节前清除这个临时目录。

```sh
cd /home/ubuntu/dev/workspace/nixos-config
nix develop
umask 077
recovery=/persist/home/ubuntu/migration-1278
work=$(mktemp -d "${XDG_RUNTIME_DIR}/secrets-migration.XXXXXX")
cp data/secrets/system.example.yaml "$work/system.yaml"
cp data/secrets/backup.example.yaml "$work/backup.yaml"
cp data/secrets/identity.example.yaml "$work/identity.yaml"
sops_bin=$(command -v sops)
```

后续凭据命令在同一个开发 shell 内运行，保留 `work` 的实际值。原密文来自上一步保存的实际构建源码。

### 逐项读取与填写

先将主 YAML 解密到私密工作目录，用编辑器核对字段：

```sh
sudo env SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/keys.txt \
  "$sops_bin" decrypt "$recovery/source/hosts/laptop2/secrets/secrets.yaml" > "$work/original.yaml"
```

| 原字段或文件 | 目标字段 |
| --- | --- |
| `ubuntu-password` | `system.yaml` → `login.passwordHash`，完整保留 hash |
| `tailscale-auth-key` | `system.yaml` → `tailscale.authKey` |
| `bark-device-token` | `system.yaml` → `notifications.barkDeviceToken` |
| `restic-password` | `backup.yaml` → `password`，使用原仓库密码 |
| `restic-repo-scaleway`、`restic-repo-r2`、`restic-repo-b2` | `backup.yaml` → 对应 `repositories.<名称>.url` |
| `restic-s3-scaleway`、`restic-s3-r2`、`restic-s3-b2` | `backup.yaml` → 对应 `repositories.<名称>.environment`，多行原样填写 |
| `wgcf.priv`、`fastestvpn.auth`、`goose.auth` | `system.yaml` → `retained.wgcfPrivateKey`、`fastestvpn`、`goose`，仅保留资料 |
| 原 Home Manager 生成的 `~/.ssh/config`、Git 身份配置 | `identity.yaml` → 原生 `ssh.hosts`、`git.identity` |

旧二进制模式 SOPS 文件是 JSON 密文，用原生解密命令读取原始文本。例如：

```sh
sudo env SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/keys.txt \
  "$sops_bin" decrypt --input-type json --output-type binary \
  "$recovery/source/hosts/laptop2/secrets/restic-s3-r2" > "$work/r2.environment"
```

另外两个仓库的环境文件同样解密到独立文件：

```sh
sudo env SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/keys.txt \
  "$sops_bin" decrypt --input-type json --output-type binary \
  "$recovery/source/hosts/laptop2/secrets/restic-s3-b2" > "$work/b2.environment"
sudo env SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/keys.txt \
  "$sops_bin" decrypt --input-type json --output-type binary \
  "$recovery/source/hosts/laptop2/secrets/restic-s3-scaleway" > "$work/scaleway.environment"
```

在编辑器中把环境文件原样填写到各自多行 YAML 字段。原 `wireless` 与供应商整份配置仍留在密文归档；新 Wi-Fi 使用 `HOME_SSID/HOME_PSK`、`TRAVEL_SSID/TRAVEL_PSK`、`IPHONE_SSID/IPHONE_PSK`、`MIFI_SSID/MIFI_PSK` 四对变量；按 `system.example.yaml` 的多行示例全部填写。若不使用某个连接，先从 `hosts/laptop2/secrets.nix` 移除对应 profile，再省略那对变量。SSID 和密码只填写在密文里。仅使用 Bark 时，将 `notifications.channels` 设为 `urls: []`。

原项目的 SSH hosts 和 Git 身份来自私有 flake 输入，并非上述密文中的独立字段。保存旧系统实际生成的 SSH 配置，在本机审阅 Git 配置的来源：

```sh
cp -L -- "$HOME/.ssh/config" "$work/ssh.conf"
git config --global --show-origin --list > "$work/git-config-origins.txt"
```

将需要的 `Host` 段填写到 `ssh.hosts`，将姓名、邮箱等身份项填写到 `git.identity`；公共别名与默认选项由新配置生成。原配置若使用 `Include`，按其中的实际路径逐份审阅。本机覆盖放入 `~/.ssh/hosts.d/*.conf` 与 `~/.config/git/local.inc`。曾单独整理过的 SSH/Git 密文可以按其实际格式解密，不能假设原项目存在这些文件。

### 从 GPG 公钥确定 SSH 与 Git 身份

先在日常 GPG 用户会话中列举，不使用 sudo：

```sh
ls /etc/ssh/gpg.*.pub
gpg --list-keys --keyid-format long --with-subkey-fingerprint --with-keygrip
```

文件名 `gpg.ios.<16位KeyID>.pub` 中的 Key ID 对应 `[A]` 认证子密钥。找到这个子密钥的完整指纹和它所属的主密钥。`gpg.ssh.ios` 填子密钥完整指纹；导出证书时使用所属主密钥完整指纹：

```sh
gpg --armor --export '主密钥1完整指纹' '主密钥2完整指纹' > "$work/public.asc"
gpg --show-keys --with-subkey-fingerprint --with-keygrip "$work/public.asc"
gpg --export-ssh-key 'ios认证子密钥完整指纹!' > "$work/ios.pub"
ssh-keygen -lf "$work/ios.pub"
ssh-keygen -lf /etc/ssh/gpg.ios.实际长KeyID.pub
```

逐个核对 `github`、`gitlab`、`mainland`、`vps`、`ios` 用途，把全部所需公钥证书放入 `gpg.publicKeys`，把认证子密钥完整指纹写入 `gpg.ssh`。只有 SSH `.pub` 时无法重建 OpenPGP 证书，需要从原生成设备或备份取得完整公钥证书。

用 `git config --show-origin --get user.signingkey` 核对旧签名选择，在 GPG 列表中找到具备 `[S]` 能力的完整子密钥指纹，填入 `gpg.signingKey`。`git.identity` 保留姓名、邮箱等原生配置；签名选择统一由前述字段生成。`ssh.hosts` 的 `IdentityFile` 改为 `/etc/ssh/gpg.<用途>.<16位长KeyID>.pub`。

这些命令列举、导出公钥。部署后，用户服务自动启用声明所对应的本机 GPG SSH 身份；需要补充的 GPG 密钥或公钥证书由本人导入，智能卡引用由 `gpg --card-status` 建立。原有身份继续保留，换钥并确认远端连接成功后才手动停用旧 keygrip。

### 加密和审阅

使用现有 `.sops.yaml` 接收者，在当前仓库生成三份新文件。若文件已经存在，用 `sops edit` 审阅；以下创建命令使用 shell 的 noclobber，避免覆盖已有密文：

```sh
install -d -m 0755 hosts/laptop2/secrets
(
set -e
set -o noclobber
sops encrypt --filename-override hosts/laptop2/secrets/system.sops.yaml \
  "$work/system.yaml" > hosts/laptop2/secrets/system.sops.yaml
sops encrypt --filename-override hosts/laptop2/secrets/backup.sops.yaml \
  "$work/backup.yaml" > hosts/laptop2/secrets/backup.sops.yaml
sops encrypt --filename-override hosts/laptop2/secrets/identity.sops.yaml \
  "$work/identity.yaml" > hosts/laptop2/secrets/identity.sops.yaml
)
```

对三份密文分别运行下面的解密命令，在本机编辑器中核对结果。SOPS 会规范化 YAML 排版；以下命令按解析后的字段和值比较，仅输出比较结果：

```sh
sudo env SOPS_AGE_KEY_FILE=/persist/var/lib/sops-nix/keys.txt \
  "$sops_bin" decrypt hosts/laptop2/secrets/identity.sops.yaml > "$work/identity-check.yaml"
python3 -c '
import sys, yaml
from pathlib import Path
source, restored = (yaml.safe_load(Path(p).read_text()) for p in sys.argv[1:])
if source != restored:
    raise SystemExit("Decrypted fields differ")
print("Decrypted fields match")
' "$work/identity.yaml" "$work/identity-check.yaml"
```

对 `system`、`backup` 同样核对。登录密码采用当前可以登录的 hash，可在私密目录中比较，不把 hash 打印到终端：

```sh
sudo getent shadow ubuntu | cut -d: -f2 > "$work/current-password.hash"
python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["login"]["passwordHash"])' \
  < "$work/system.yaml" > "$work/target-password.hash"
cmp -s "$work/current-password.hash" "$work/target-password.hash" && printf 'Login password hash matches\n'
```

如果不同，先确认差异并重新填写、加密。核对完成后，将三份密文加入 Git，供 Git-backed flake 读取：

```sh
git add -- hosts/laptop2/secrets/system.sops.yaml \
  hosts/laptop2/secrets/backup.sops.yaml hosts/laptop2/secrets/identity.sops.yaml
```

关闭编辑器，确认 `work` 仍是本节创建的具体目录，然后清除其中明文：

```sh
printf '%s\n' "$work"
rm -r -- "$work"
unset work
```

原密文、持久 age key 和独立保存的恢复资料继续保留。

## 构建与文件审阅

在当前仓库根目录构建。完整 E2E 需要 KVM；测试使用合成凭据。构建期间保留旧图形会话和网络，先完成耗时步骤：

```sh
cd /home/ubuntu/dev/workspace/nixos-config
recovery=/persist/home/ubuntu/migration-1278
nix build --no-link --no-update-lock-file --max-jobs 1 --cores 2 \
  .#checks.x86_64-linux.e2e
nix build --no-update-lock-file --out-link "$recovery/target-system" \
  .#nixosConfigurations.laptop2.config.system.build.toplevel
nix build --no-update-lock-file --out-link "$recovery/target-home" \
  .#nixosConfigurations.laptop2.config.home-manager.users.ubuntu.home.activationPackage
find "$recovery/target-home/home-files/" \( -type f -o -type l \) -printf '%P -> %l\n'
```

对清单中的已有路径用 `ls -ld`、`readlink -e`、`findmnt -T` 审阅。旧 Home Manager 管理的链接由其正常生命周期接续；个人普通文件先保存，冲突逐项处理。整个 `activate` 包含 profile 初始化等动作，不能把执行它当作纯只读审阅。

将当前需要的节点和规则手动写入 `$recovery/network-next/`。`outbounds.json` 使用原生 `outbounds` 和 `endpoints` 数组，合计至少一个具体节点；接受 JSONC。示例结构为：

```json
{
  "outbounds": [
    {"type": "socks", "tag": "node-a", "server": "proxy.example.net", "server_port": 1080}
  ],
  "endpoints": []
}
```

示例中的服务器须替换为实际节点，并按协议补齐认证。旧供应商资料需本人取舍并填写，不会自动生成节点。

| 原入口 | 目标入口和内容 |
| --- | --- |
| `/usr/local/etc/sing-box/outbounds.json` | 同一路径，使用当前 sing-box 的节点与 endpoint 格式；保留原节点参数和需要的出口标签 |
| 原 `rules.json` 中域名规则、dnsmasq 中个人域名规则 | `network-next/route.d/*.json`，原生 route 子集，动作使用 `direct`、`proxy`、`tailnet`、`private`、`reject` |
| 原 IP、端口、协议及任意节点路由 | `network-next/connection.d/*.json`，原生连接 route；与共享规则按文件名统一排序 |
| 原 `experimental.json` | 控制 API 使用 `site.network.clash` 声明；按实际使用情况填写地址、密钥等选项 |

例如一份 `route.d/50-local.json`：

```json
{
  "rules": [
    {"domain_suffix": ["example.cn"], "action": "route", "outbound": "direct"},
    {"domain": ["service.example.net"], "action": "route", "outbound": "proxy"}
  ]
}
```

原 dnsmasq 的自动生成列表由声明的规则集接续；逐个审阅 `/usr/local/etc/dnsmasq/dnsmasq.d/` 中自己添加的规则。个性化规则要进入新片段，而不是留下只被旧 DNS 读取的文件。创建空的 `route.d`、`connection.d` 也合法：

```sh
install -d -m 0700 "$recovery/network-next/route.d" "$recovery/network-next/connection.d"
```

Tailscale 保留出口节点和三个 RFC1918 私网段公告，核对管理端的批准状态及访问规则。访问私有 Nix 源所需的本机凭据独立保留，不把 token 写入公开源码或 store。

## 停止应用并保存数据

使用当前桌面的独立终端（如 Kitty）继续操作。按下面的数据分组，先保存工作并正常退出对应应用，让数据库完成写入，再复制文件。退出编辑器前，把操作终端留在编辑器之外；桌面和登录管理器保持运行。

```sh
recovery=/persist/home/ubuntu/migration-1278
umask 077
pgrep -ai -u ubuntu 'firefox|chrome|code|bitwarden|anytype'
install -d -m 0700 "$recovery/apps" "$recovery/fcitx5-config" "$recovery/fcitx5-data"
```

进程列表用于查看仍在运行的应用；`pgrep` 无结果时返回 1。浏览器和托盘应用使用各自的“退出”操作结束后台进程。每组复制前确认对应应用已经退出，完成后保持该应用关闭直到重启；若期间再次使用，在重启前退出并重新保存该组数据。Docker 数据沿用现有 Btrfs 目录；本次不制作 Docker 副本，也不执行清理。

### 输入法

实机的 Fcitx 配置和词库目前在 tmpfs，第一次重启前完成保存。在当前桌面的终端中让输入法正常退出：

```sh
fcitx5-remote --check -e
pgrep -a -u ubuntu -x fcitx5
```

输入法已经退出时，`fcitx5-remote` 返回未运行状态。确认 Fcitx 进程已结束后再复制；终端可以继续输入英文和执行命令：

```sh
cp -aL -- "$HOME/.config/fcitx5/." "$recovery/fcitx5-config/"
rsync -aHAX --exclude='/themes/' \
  "$HOME/.local/share/fcitx5/" "$recovery/fcitx5-data/"
chmod -R u+rwX,go-rwx "$recovery/fcitx5-config" "$recovery/fcitx5-data"
install -d -m 0700 /persist/home/ubuntu/.config/fcitx5
install -d -m 0700 /persist/home/ubuntu/.local/share/fcitx5
cp -ai -- "$recovery/fcitx5-config/." /persist/home/ubuntu/.config/fcitx5/
cp -ai -- "$recovery/fcitx5-data/." /persist/home/ubuntu/.local/share/fcitx5/
```

`cp -aL` 将旧声明式配置链接保存为可写内容；词库保留原文件和链接，主题由新 Home Manager 提供。核对 `profile`、`conf/pinyin.conf`、`pinyin/user.dict`、`pinyin/user.history` 等实际存在的文件。目标若已有内容，审阅覆盖提示；旧 store 链接需先保存并逐个移走，再复制对应普通文件。

### Firefox 与 Bitwarden

Firefox 只保存 cookie、登录凭据和站点状态等既定数据，排除站点缓存；两个 profile 分别保存。下面的 rsync 仅写入恢复目录：

```sh
for profile in default origin; do
  [ -d "$HOME/.config/mozilla/firefox/$profile" ] || continue
  mkdir -p "$recovery/firefox/$profile"
  rsync -aHAXm --include='*/' \
    --include='/cookies.sqlite' --include='/cookies.sqlite-wal' \
    --include='/logins.json' --include='/key4.db' --include='/key4.db-wal' \
    --include='/containers.json' --include='/sessionstore.jsonlz4' \
    --include='/sessionstore-backups/***' \
    --include='/webappsstore.sqlite' --include='/webappsstore.sqlite-wal' \
    --include='/storage.sqlite' --include='/storage.sqlite-wal' \
    --include='/storage/default/*/.metadata-v2' \
    --include='/storage/default/*/ls/***' --include='/storage/default/*/idb/***' \
    --include='/storage/permanent/https*/*.metadata-v2' \
    --include='/storage/permanent/https*/ls/***' --include='/storage/permanent/https*/idb/***' \
    --exclude='*' "$HOME/.config/mozilla/firefox/$profile/" "$recovery/firefox/$profile/"
done
for relative in '.config/Bitwarden/data.json' '.config/Bitwarden CLI/data.json'; do
  [ -f "$HOME/$relative" ] || continue
  rsync -aHAXR "$HOME/./$relative" "$recovery/apps/"
done
```

Bitwarden 仅保留加密 vault 所在的 `data.json`；恢复时重新登录，使用主密码解锁。Firefox 的书签、搜索和其他声明式设置由对应代次重新生成。

### 其他应用与个人配置

Chrome、Code、Anytype 以及 GPG、SSH、Git 用户资料保留部署前副本。退出对应应用，并结束正在使用密钥环的 GPG 操作；复制密钥环前停止其后台进程：

```sh
gpgconf --kill all
```

复制期间保持 GPG、SSH 鉴权和 Git 签名操作停止。下面只复制存在的项目，链接保持为链接；KDEConnect 和 KWallet 随后在桌面状态一节处理：

```sh
for relative in \
  '.config/google-chrome' '.config/Code' '.config/anytype' \
  '.gnupg' '.ssh' '.config/git'; do
  [ -d "$HOME/$relative" ] || continue
  rsync -aHAXR \
    --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache' \
    --exclude='DawnCache' --exclude='DawnGraphiteCache' --exclude='DawnWebGPUCache' \
    --exclude='Crashpad' --exclude='Shared Dictionary' --exclude='logs' \
    --exclude='S.gpg-agent*' --exclude='S.dirmngr' \
    "$HOME/./$relative" "$recovery/apps/"
done
```

这些副本独立于日常 Restic 选择。GPG 的配置链接依靠已固定的旧 Home Manager 保持可读；若 `~/.gnupg/sshcontrol` 是旧声明式链接，再保存一份其内容，供恢复 SSH 注册时本人审阅：

```sh
if [ -e "$HOME/.gnupg/sshcontrol" ]; then
  cp -L -- "$HOME/.gnupg/sshcontrol" "$recovery/sshcontrol"
  chmod 0600 "$recovery/sshcontrol"
fi
```

旧 Home Manager 撤下自己管理的链接时可能移除 `sshcontrol`。声明中的身份由用户服务通过 `Use-for-ssh` 持久注册；备份的 `sshcontrol` 可用于核对额外身份，并由本人审阅后恢复。旧 GNOME Keyring 数据按已确定的选择留在原盘，不进行迁移。

## 目录与文件交接

`profiles/laptop/persistence.nix` 列出目标路径。先核对 `findmnt -T`、`readlink -e` 和 `stat`，已位于相同持久路径的数据保持原位。

| 内容 | 处理 |
| --- | --- |
| 大应用目录、开发目录、个人文件、Docker | 已在持久盘，继续使用原路径 |
| Fcitx 配置和词库 | 使用前节的明确复制步骤 |
| Tailscale | 后节从旧私有目录复制到 `/persist/var/lib/tailscale` |
| SOPS 与 Secure Boot | 沿用既有密钥，仅按下文调整目录权限 |
| GTK、KDE、显示器设置 | 个人可写内容仍在 tmpfs 时，逐项保存到对应持久路径 |
| GPG 与 SSH | 保留用户身份资料；公钥由声明派生，对应的本机 GPG SSH 身份自动启用 |

### 桌面状态

本节处理实际存在且需要保留的个人桌面设置。复制前关闭对应设置工具或应用；KDEConnect、KWallet 等后台服务也需结束写入。已经退出的组件可以在当前终端处理。

需要一起保存正在使用的 Plasma 桌面、钱包和显示器状态时，先在桌面正常注销，让组件保存设置，再切换到 TTY，以 ubuntu 登录后继续本节。登录界面保持运行。仅切换 TTY 会让原图形会话继续运行；注销后也应确认对应后台服务已经退出，再复制它们的数据。在新的终端重新设置恢复目录：

```sh
recovery=/persist/home/ubuntu/migration-1278
umask 077
```

保存已退出的 KDEConnect、KWallet 的现有数据：

```sh
for relative in '.config/kdeconnect' '.local/share/kwalletd'; do
  [ -d "$HOME/$relative" ] || continue
  rsync -aHAXR "$HOME/./$relative" "$recovery/apps/"
done
```

例如交接现有 Plasma 触控板设置：

```sh
relative=.config/kcminputrc
findmnt -T "$HOME/$relative"
readlink -e "$HOME/$relative"
stat -c '%a %U:%G %n' "$HOME/$relative"
install -d -m 0700 "$recovery/desktop/$(dirname "$relative")"
cp -aL -- "$HOME/$relative" "$recovery/desktop/$relative"
```

仅在文件存在且目标尚无更新设置时，执行以下安装；目标已经是源文件的持久位置时，只保留恢复副本：

```sh
install -m 0600 "$recovery/desktop/$relative" "/persist/home/ubuntu/$relative"
```

对 `.config/kwalletrc`、`kdeglobals`、`kwinrc`、`kwinoutputconfig.json`、`plasmashellrc`、`plasma-org.kde.plasma.desktop-appletsrc` 重复上面的单文件步骤，并填写完整的 `.config/…` 相对路径。目录类的个人设置包括 `.config/gtk-2.0`、`.config/gtk-3.0`、`.config/gtk-4.0`、`.config/plasma-workspace`、`.local/share/kscreen`、`.config/kanshi`、`.config/autorandr`；只对实际存在的本机可写内容保存和交接：

```sh
relative=.config/autorandr
findmnt -T "$HOME/$relative"
readlink -e "$HOME/$relative"
install -d -m 0700 "$recovery/desktop/$(dirname "$relative")"
cp -a -- "$HOME/$relative" "$recovery/desktop/$relative"
install -d -m 0700 "/persist/home/ubuntu/$relative"
cp -ai -- "$recovery/desktop/$relative/." "/persist/home/ubuntu/$relative/"
```

### Home Manager 文件与目录权限

与新 Home Manager 同名的旧声明式配置由新声明接续，不把旧 store 内容批量转换为个人覆盖。发生普通文件冲突时，先退出使用该文件的应用，保存该具体文件，再移动到恢复目录；例如：

```sh
relative=.config/example/settings
findmnt -T "$HOME/$relative"
ls -ld -- "$HOME/$relative"
install -d -m 0700 "$recovery/conflicts/$(dirname "$relative")"
mv -i -- "$HOME/$relative" "$recovery/conflicts/$relative"
```

示例中的路径须替换为已核对的实际文件。挂载点按其所属应用处理，不能直接按普通文件搬移。

保存完资料后收紧已确认的目录权限，仅改变目录本身：

```sh
sudo chmod 0700 /home/ubuntu /persist/home/ubuntu
chmod 0700 /home/ubuntu/.ssh
sudo chmod 0700 /persist/home/ubuntu/.ssh /persist/etc/secureboot
stat -c '%a %U:%G %n' /home/ubuntu /persist/home/ubuntu /home/ubuntu/.ssh
sudo stat -c '%a %U:%G %n' /persist/home/ubuntu/.ssh /persist/etc/secureboot /persist/var/lib/sops-nix
```

已有 GPG 与 SOPS 目录的 0700、签名私钥的 0400、age key 的 0600 沿用原值。impermanence 为新目录提供默认权限，已有目录在这里明确处理。

SSH 主机密钥按实际存在的身份保存。先列举，不输出密钥内容：

```sh
sudo find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -printf '%m %u:%g %p\n'
```

若主机密钥仍位于 tmpfs，停止 sshd，再逐个保存和安装，例如 Ed25519：

```sh
sudo systemctl stop sshd.service
sudo install -d -m 0700 "$recovery/ssh-host-keys"
sudo cp -aL -- /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub "$recovery/ssh-host-keys/"
sudo install -d -m 0755 /persist/etc/ssh
sudo install -m 0600 -o root -g root "$recovery/ssh-host-keys/ssh_host_ed25519_key" /persist/etc/ssh/ssh_host_ed25519_key
sudo install -m 0644 -o root -g root "$recovery/ssh-host-keys/ssh_host_ed25519_key.pub" /persist/etc/ssh/ssh_host_ed25519_key.pub
```

RSA 使用相同方法处理实际存在的文件。当前未启用 sshd 且没有主机密钥时，无须为了迁移创建身份。派生的 `/etc/ssh/gpg.*.pub` 在新启动中由身份发布器生成；前面的指纹核对确认其对应关系。若首次启动日志报告已有持久文件冲突，再保存并逐个移走该具体公钥路径，重启 `site-identity.service`。

## 安装启动代次

此时旧 Tailscale、代理与 DNS 继续运行，构建产物已经准备好。在当前终端安装启动代次，再交接最后的网络状态。`boot` 设置下次启动的系统，当前运行的系统和 Home Manager 配置继续使用旧代次：

```sh
cd /home/ubuntu/dev/workspace/nixos-config
recovery=/persist/home/ubuntu/migration-1278
sudo nixos-rebuild boot --flake .#laptop2
readlink -e /nix/var/nix/profiles/system
readlink -e "$recovery/target-system"
readlink -e /nix/var/nix/profiles/system-1278-link
sudo bootctl list
sudo sbctl status
```

核对新 profile 与已验收的产物一致，1278 仍指向原产物且启动菜单保留其入口。安装失败时继续停留在旧系统，先解决安装问题。

### Tailscale 身份

停服务后复制；原私有目录保留原 UID 和内容，供旧代次使用。目标路径若已有另一次运行的身份，先保存并确认采用哪一份：

```sh
sudo systemctl stop tailscaled.service
sudo cp -a -- /persist/var/lib/private/tailscale "$recovery/tailscale-original"
sudo install -d -m 0700 -o root -g root /persist/var/lib/tailscale
sudo rsync -aHAX --chown=root:root --ignore-existing \
  /persist/var/lib/private/tailscale/ /persist/var/lib/tailscale/
sudo stat -c '%a %u:%g %n' /persist/var/lib/tailscale /persist/var/lib/tailscale/tailscaled.state
```

`--ignore-existing` 保留目标已有文件；若目标原先非空，完成逐项核对后才继续，不能把一次复制完成当作身份已确认。新服务使用 root 所有的 `/var/lib/tailscale/tailscaled.state`。

### 代理配置

旧配置停止写入后保存，新格式只在此时安装。先检查新文件已准备完整：

```sh
ls -l "$recovery/network-next/outbounds.json"
sudo systemctl stop sing-box.service
sudo cp -a -- /persist/usr/local/etc/sing-box "$recovery/sing-box-original"
if [ -d /persist/usr/local/etc/network-policy ]; then
  sudo cp -a -- /persist/usr/local/etc/network-policy "$recovery/network-policy-original"
fi
sudo install -d -m 0755 /persist/usr/local/etc/sing-box
sudo install -m 0600 -o root -g root "$recovery/network-next/outbounds.json" \
  /persist/usr/local/etc/sing-box/outbounds.json
sudo install -d -m 0700 /persist/usr/local/etc/network-policy/route.d
sudo install -d -m 0700 /persist/usr/local/etc/network-policy/connection.d
find "$recovery/network-next/route.d" -maxdepth 1 -type f \
  \( -name '*.json' -o -name '*.jsonc' \) \
  -exec sudo install -m 0600 -o root -g root -t /persist/usr/local/etc/network-policy/route.d -- {} +
find "$recovery/network-next/connection.d" -maxdepth 1 -type f \
  \( -name '*.json' -o -name '*.jsonc' \) \
  -exec sudo install -m 0600 -o root -g root -t /persist/usr/local/etc/network-policy/connection.d -- {} +
sync
sudo reboot
```

准备文件由 `umask 077` 创建；安装后的节点及片段应为 root 所有、0600。完整运行时策略在新系统中由 `network-policy check` 校验。若决定此时取消部署，先按回退节恢复原代理配置与启动默认项，再继续使用旧系统。

## 首次启动

登录后先在终端确认基础服务与实际挂载，再打开需要验收的应用。可以使用图形终端；图形登录不可用时，从 TTY 执行同样的检查：

```sh
nixos-version --json
readlink -e /run/current-system
systemctl --failed
systemctl status home-manager-ubuntu.service
journalctl -b -u home-manager-ubuntu.service -u sops-install-secrets.service -u site-identity.service
findmnt -T "$HOME/.config/fcitx5"
findmnt -T "$HOME/.local/share/fcitx5"
findmnt -T /var/lib/docker
findmnt -T /var/lib/tailscale
df -hT / /tmp /run /persist
sudo network-policy check
sudo tailscale status
nmcli connection show
backup-status
```

正常启动会执行 Home Manager 配置管理、impermanence 挂载和 tmpfiles 初始化；Firefox 书签与搜索由声明决定。Home Manager 若遇到普通文件冲突，使用上一节的单文件保存方式处理后运行 `sudo systemctl restart home-manager-ubuntu.service`。配置冲突不会阻止图形登录，但对应配置需处理成功后验收。

GPG 密钥环保留在持久目录中。核对派生公钥，按需导入公钥证书，并检查自动注册结果：

```sh
gpg --show-keys --with-subkey-fingerprint --with-keygrip /run/site-identity/ubuntu/current/public.asc
jq . /run/site-identity/ubuntu/current/manifest.json
gpg --import /run/site-identity/ubuntu/current/public.asc
gpg --list-secret-keys --with-subkey-fingerprint --with-keygrip
journalctl --user -b -u site-gpg-ssh-identities.service
ssh-add -L
```

注册服务按用途报告缺少的 GPG 子密钥或智能卡引用；补齐资料后自动重试，也可运行 `systemctl --user restart site-gpg-ssh-identities.service` 立即核对。额外的旧 `sshcontrol` 身份可由本人审阅后恢复。验证常用 SSH 连接和 Git 签名；换钥期间保留旧身份，确认远端切换后再手动停用。

分别登录 Sway、i3、Plasma，验收输入法学习记录、锁屏、Wi-Fi、显示器、DNS、代理及 Tailnet/出口访问。Sway 用 Super+P 打开 wdisplays 保存当前屏幕组合；i3 调整后用 `autorandr --save office` 保存；Plasma 使用原生显示设置。实测媒体播放、麦克风、耳机、外屏、触控板、合盖与休眠。

Docker 使用原 Btrfs 数据目录；`local` 日志驱动对新建容器生效。现有容器通过所属 Compose 或服务正常重建即可采用新默认值，重建时保留已有挂载与卷。

备份频率和重试间隔按仓库配置，使用[受控启用流程](backup.md#受控启用)逐步核对真实云端请求与下载预算，再启用自动任务。网络诊断位于独立 `network` journal，混合查询使用 `--namespace='*'`；备份日志留在系统默认 journal。

## 回退

### 选择旧 generation

当前系统还能操作时，重启前先正常退出需要保存数据的应用，按前文的方法将新产生的 Fcitx 数据及需要保留的应用数据另存到 `$recovery/after-attempt/`。原生 Tailscale 状态在停止 `tailscaled.service` 后另存；保存桌面状态时按前文正常注销。只有启动菜单可用时，先启动旧系统，在打开相关应用前保留尝试期间的持久数据。

启动菜单选择 **generation 1278**。若当前系统可以登录，也可以在图形终端或 TTY 中先将默认启动项恢复到固定的旧产物：

```sh
sudo nix-env --profile /nix/var/nix/profiles/system --set \
  "$(readlink -e /nix/var/nix/gcroots/laptop2-before-migration/system)"
sudo /nix/var/nix/gcroots/laptop2-before-migration/system/bin/switch-to-configuration boot
sudo reboot
```

从启动菜单进入旧系统后，也执行上面的前两条命令，将旧产物设为默认启动项；已经运行旧系统时无需再次重启。

### 恢复旧网络与 Home Manager

旧系统启动后停止代理，保存尝试期间的文件，然后恢复原配置。目录已经有名为 `sing-box-after-attempt` 的副本时，先换一个新名字：

```sh
recovery=/persist/home/ubuntu/migration-1278
sudo systemctl stop sing-box.service
sudo cp -a -- /persist/usr/local/etc/sing-box "$recovery/sing-box-after-attempt"
sudo cp -ai -- "$recovery/sing-box-original/." /persist/usr/local/etc/sing-box/
sudo systemctl start sing-box.service tailscaled.service
sudo tailscale status
journalctl --namespace='*' -b -u sing-box.service -u tailscaled.service -u home-manager-ubuntu.service
```

旧 sing-box 继续读取自己的 `rules.json`、`experimental.json`；原 DNS 配置未改写。旧 Tailscale 使用保留下来的 `/persist/var/lib/private/tailscale`。新路径的状态保留作另一次尝试的资料，不覆盖旧私有目录。

若在代理交接前就取消部署，尚未生成 `sing-box-original`，原配置仍在原位，无须执行该恢复段。Home Manager 普通文件冲突按日志列出的路径逐项保存并移开，再启动旧激活服务。

新配置把 Fcitx 放到持久盘，而旧配置仍使用 tmpfs。退出输入法后，将需要保留的最新配置与学习记录复制回用户路径；主题由旧 Home Manager 管理：

```sh
fcitx5-remote --check -e
pgrep -a -u ubuntu -x fcitx5
```

确认输入法进程已结束后复制：

```sh
install -d -m 0700 "$HOME/.config/fcitx5" "$HOME/.local/share/fcitx5"
cp -ai -- /persist/home/ubuntu/.config/fcitx5/. "$HOME/.config/fcitx5/"
rsync -aHAX --exclude='/themes/' /persist/home/ubuntu/.local/share/fcitx5/ "$HOME/.local/share/fcitx5/"
sudo systemctl restart home-manager-ubuntu.service
```

若复制目标是旧声明式 store 链接，先保存该具体链接，再移走并复制对应普通文件。Home Manager 激活成功后，正常注销并重新登录图形会话，让输入法加载恢复后的设置；从 TTY 操作时返回登录界面登录。以后重新启动前，再次保存旧系统 tmpfs 中的新学习记录。

### 应用数据恢复

旧程序能读取当前数据时继续使用。若拒绝读取或状态异常，先退出应用，保存新数据，再恢复部署前副本。以下以 Code 为例，先确认实际挂载并成功卸载：

```sh
recovery=/persist/home/ubuntu/migration-1278
install -d -m 0700 "$recovery/after-attempt"
findmnt -M /home/ubuntu/.config/Code
sudo umount /home/ubuntu/.config/Code
```

卸载成功后，将当前目录移到尚未存在的恢复位置，再放回部署前副本：

```sh
mv -T -- /persist/home/ubuntu/.config/Code "$recovery/after-attempt/Code" &&
cp -a -- "$recovery/apps/.config/Code" /persist/home/ubuntu/.config/Code &&
sudo mount --bind /persist/home/ubuntu/.config/Code /home/ubuntu/.config/Code
```

先确认该路径确实是独立 bind mount，相关进程已退出。`umount` 失败时停止处理，不使用 lazy/force；其他应用按其实际挂载边界操作。这里保留整个新目录，使恢复后的目录不会混入新版本数据库。

Firefox 的 profile 是其父目录持久挂载内的子目录。停止 Firefox 后，保存并移走当前 profile，再恢复已选的数据；以 `default` 为例：

```sh
recovery=/persist/home/ubuntu/migration-1278
install -d -m 0700 "$recovery/after-attempt"
mv -T -- /persist/home/ubuntu/.config/mozilla/firefox/default "$recovery/after-attempt/firefox-default" &&
mkdir -m 0700 "$HOME/.config/mozilla/firefox/default" &&
cp -a -- "$recovery/firefox/default/." "$HOME/.config/mozilla/firefox/default/"
sudo systemctl restart home-manager-ubuntu.service
```

`origin` 同样处理。Home Manager 重新生成声明的搜索与书签，其他缺失的默认文件由 Firefox 创建。

Bitwarden 仅放回对应 `data.json`。退出客户端后选择应用目录，确认挂载并成功卸载：

```sh
app=Bitwarden
findmnt -M "$HOME/.config/$app"
sudo umount "$HOME/.config/$app"
```

对于 CLI，将 `app` 设为 `Bitwarden CLI`。确认部署前 `data.json` 副本存在、恢复目标尚未使用，然后执行：

```sh
recovery=/persist/home/ubuntu/migration-1278
install -d -m 0700 "$recovery/after-attempt"
mv -T -- "/persist/home/ubuntu/.config/$app" "$recovery/after-attempt/$app" &&
mkdir -m 0700 "/persist/home/ubuntu/.config/$app" &&
cp -a -- "$recovery/apps/.config/$app/data.json" "/persist/home/ubuntu/.config/$app/data.json" &&
sudo mount --bind "/persist/home/ubuntu/.config/$app" "$HOME/.config/$app"
```

重新登录并使用主密码解锁。GPG/SSH 仅在本人确认需要时恢复其具体资料，不批量覆盖仍正常使用的密钥环。

### ESP 无法启动时

用 NixOS 安装介质启动，确认磁盘和分区。下面设备名来自 laptop2 的现有磁盘声明；先用 `lsblk -f` 对照，再解锁和挂载：

```sh
lsblk -f
sudo cryptsetup open /dev/disk/by-id/nvme-KIOXIA-EXCERIA_G2_SSD_43AA20S8KMK5-part3 crypt0
sudo mount -t tmpfs -o mode=755 tmpfs /mnt
sudo mkdir -p /mnt/persist /mnt/nix /mnt/boot
sudo mount -o subvol=persist /dev/mapper/crypt0 /mnt/persist
sudo mount -o subvol=nix /dev/mapper/crypt0 /mnt/nix
sudo mount /dev/disk/by-id/nvme-KIOXIA-EXCERIA_G2_SSD_43AA20S8KMK5-part2 /mnt/boot
sudo tar -tf /mnt/persist/home/ubuntu/migration-1278/esp.tar
```

确认归档包含原 `EFI/BOOT`、`EFI/Linux`、`EFI/nixos` 等实际启动文件后恢复：

```sh
sudo tar -xpf /mnt/persist/home/ubuntu/migration-1278/esp.tar -C /mnt/boot
sync
sudo umount /mnt/boot /mnt/nix /mnt/persist
sudo umount /mnt
sudo cryptsetup close crypt0
sudo reboot
```

若介质已经解锁 crypt0 或挂载这些分区，使用现有挂载，不重复执行对应步骤。保持固件现有 Secure Boot keys；必要时从固件选择磁盘上的 `EFI/BOOT/BOOTX64.EFI`，启动后再使用旧系统的启动安装命令恢复菜单。系统产物、启动文件和签名材料都有对应副本，但固件或硬件故障仍需安装介质处理。

## 历史备份与恢复材料保留

新作业用 `site:laptop2` 标签维护快照，旧无标签快照保留。以后决定清理时，在本机正确配置仓库和密码的 Restic 环境中先预览：

```sh
restic snapshots --host laptop2 --tag ''
restic forget --host laptop2 --tag '' --group-by host,tags \
  --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 75 --dry-run
```

核对范围及其他仓库可恢复后，才按个人决定去掉 `--dry-run` 并单独运行 `restic prune`。

部署成功并完成三次正常升级和重启后，可删除本文。GC roots、原密文及恢复副本按各自用途单独释放；清理前确认仍需保留的离线恢复资料已经另存。
