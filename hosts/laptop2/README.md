# laptop2

这台机器使用 laptop profile，个人用户为 `ubuntu`，UID 为 `1000`。系统与 Home Manager 的 `stateVersion` 均为 `22.11`，系统时区为 `America/New_York`。

- 磁盘、LUKS2、Btrfs 子卷与随机加密 swap 见 [disko.nix](disko.nix) 和 [硬件配置](hardware-configuration.nix)；持久根为 `/persist`，Secure Boot 由 [secureboot.nix](secureboot.nix) 通过 Lanzaboote 管理 `/persist/etc/secureboot`。
- `/` 为 `16 GiB` tmpfs；`/tmp` 上限为内存的 `80%`。日常空间排查与临时目录持久化见 [本机配置](../../docs/local-state.md#tmpfs-占用与临时持久化)。
- 备份仓库仅由本机独占使用，开启受控陈旧锁恢复。各目标的检查分片与频率在 [default.nix](default.nix) 中按下方账户预算设置，凭据绑定见 [secrets.nix](secrets.nix)。
- Tailscale 公告出口节点与三个 RFC1918 私网段，同时关闭远端 DNS 与路由接受；转发流量遵循 [网络策略](../../docs/network.md)。
- Docker 使用固定网桥地址 `172.17.0.1/16`，供宿主与容器共用本地 `oranc` 二进制缓存代理及面向容器的 `harmonia` 只读 `/nix/store` 缓存，见 [构建缓存](../../docs/cache.md)。

日常构建、升级与回退见 [主机维护](../../docs/maintenance.md)。

## 裸机安装与离线引导恢复

全新磁盘或灾难恢复在 NixOS 安装介质中执行（若主板已开启自定义 Secure Boot，引导官方安装介质前先在固件设置中临时关闭 Secure Boot 并保留已注册密钥，恢复完成后重新开启）。先用 `lsblk -f` 核对目标 NVMe 设备路径与 [disko.nix](disko.nix) 中的 `/dev/nvme0n1` 一致，并准备好离线保存的 SOPS age 私钥、Restic 凭据及代理节点文件。

### 1. LUKS2 分区格式化与口令注册

`disko.nix` 在建表阶段读取 `/tmp/crypt.key` 初始化 `crypt0`，并为 GPT 分区写入 `disk-laptop2-{boot,ESP,primary0,swap}` 分区标签。先在内存中生成一次性密钥完成分区与挂载，再注册开机交互口令并移除临时密钥槽：

```sh
umask 077
tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 > /tmp/crypt.key
nix --extra-experimental-features 'nix-command flakes' build --out-link /tmp/disko-laptop2 \
  .#nixosConfigurations.laptop2.config.system.build.diskoScript
sudo /tmp/disko-laptop2

luks_part=/dev/disk/by-partlabel/disk-laptop2-primary0
sudo cryptsetup luksAddKey "$luks_part" --key-file /tmp/crypt.key
sudo cryptsetup luksRemoveKey "$luks_part" /tmp/crypt.key
rm -f /tmp/crypt.key
```

执行完成后，`/mnt`（tmpfs）、`/mnt/boot`（ESP）、`/mnt/nix` 与 `/mnt/persist`（Btrfs 子卷）均已就绪。

### 2. Secure Boot 密钥与离线凭据交接

首次安装前将离线备份的 SOPS age 私钥、Secure Boot PKI 目录及初始代理节点写入 `/mnt/persist`；若为全新主板首次启用 Secure Boot，先在固件进入 Setup Mode，安装阶段创建新密钥并在首次进入系统后执行 `sudo sbctl enroll-keys --microsoft`：

```sh
sudo install -d -m 0700 -o root -g root \
  /mnt/persist/var/lib/sops-nix \
  /mnt/persist/etc/secureboot \
  /mnt/persist/usr/local/etc/sing-box \
  /mnt/persist/usr/local/etc/network-policy/route.d \
  /mnt/persist/usr/local/etc/network-policy/connection.d

# 放入离线备份的 SOPS age 私钥与初始代理配置（权限均为 root:root 0600）
sudo install -m 0600 -o root -g root /path/to/offline/keys.txt \
  /mnt/persist/var/lib/sops-nix/keys.txt
sudo install -m 0600 -o root -g root /path/to/offline/outbounds.json \
  /mnt/persist/usr/local/etc/sing-box/outbounds.json

# 若已有离线备份的 /etc/secureboot 则原样拷入；否则预先生成签名密钥供 Lanzaboote 签发 UKI
sudo mkdir -p /mnt/etc/secureboot
sudo mount --bind /mnt/persist/etc/secureboot /mnt/etc/secureboot
# 全新初始化无备份时执行：
# sudo nix shell nixpkgs#sbctl -c sbctl create-keys -e /mnt/persist/etc/secureboot/keys -d /mnt/persist/etc/secureboot/GUID
```

若需从 Restic 仓库恢复持久资料，先恢复到独立空目录审阅，再按属主与权限拷入 `/mnt/persist`（覆盖 `/persist/etc/ssh`、`/persist/var/lib/tailscale`、`/persist/home/ubuntu/.gnupg`、KWallet、Fcitx5、Firefox/Bitwarden 等核心路径，详见 [备份恢复演练](../../docs/backup.md#独立恢复演练)）：

```sh
sudo mkdir -m 0700 /tmp/restic-restore
sudo env RESTIC_REPOSITORY_FILE=/path/to/repo-url RESTIC_PASSWORD_FILE=/path/to/password \
  restic restore latest --tag site:laptop2 --target /tmp/restic-restore --verify
```

### 3. 安装系统与首次启动核验

```sh
sudo nixos-install --no-root-passwd --flake .#laptop2
sync
sudo umount -R /mnt
sudo cryptsetup close crypt0
sudo reboot
```

通过 Plymouth Breeze 输入 LUKS 口令并登录桌面（或 TTY）后，依次核对启动签名、SOPS 解密、GPG/SSH 身份自动注册、Lockdown 策略及备份状态：

```sh
sudo sbctl status
systemctl --failed --no-pager
systemctl --user --failed --no-pager
sudo network-policy check
sudo network-ipv6 status
sudo tailscale status
ssh-add -L
backup-status
```

若首次初始化了新的 GPG 环境，导入发布出的公钥证书并触发注册：`gpg --import /run/site-identity/ubuntu/current/public.asc && systemctl --user restart site-gpg-ssh-identities.service`。

### 4. ESP 启动项应急重建

当固件更新或 ESP 损坏导致无法引导时，用 NixOS 安装介质解锁并挂载现有子卷（若分区标签不可用，也可按 `lsblk -f` 查到的实际第 2、3 分区设备节点挂载），重新安装已签名的启动项：

```sh
sudo cryptsetup open /dev/disk/by-partlabel/disk-laptop2-primary0 crypt0
sudo mount -t tmpfs -o mode=755 tmpfs /mnt
sudo mkdir -p /mnt/persist /mnt/nix /mnt/boot /mnt/etc/secureboot
sudo mount -o subvol=/persist /dev/mapper/crypt0 /mnt/persist
sudo mount -o subvol=/nix /dev/mapper/crypt0 /mnt/nix
sudo mount /dev/disk/by-partlabel/disk-laptop2-ESP /mnt/boot
sudo mount --bind /mnt/persist/etc/secureboot /mnt/etc/secureboot
sudo nixos-enter --root /mnt -c '/nix/var/nix/profiles/system/bin/switch-to-configuration boot && sbctl verify'
sync
sudo umount -R /mnt
sudo cryptsetup close crypt0
```

## 备份账户与预算

账户约束与调度校准依据：

| 仓库 | 预算与策略 |
| --- | --- |
| B2 | 免费账户控制台对 Class B/C 请求各设 `2,500` 次日上限及 `1 GB` 日下载上限（见 [Caps & Alerts](https://www.backblaze.com/docs/en/cloud-storage-data-caps-and-alerts)）。[default.nix](default.nix) 将 `b2` 设为 `checkPartitions = 24`、`minimumIntervalSeconds.check = 14 * 86400`、`health.check = 28 * 86400`、每窗口最多 1 次自动备份尝试，使单次分片检查与维护请求量远低于日限额。 |
| R2 Standard | 以免费额度为主，存储和 Class A/B 请求分别计费，调整频率或范围前核对 [R2 定价](https://developers.cloudflare.com/r2/pricing/)。 |
| Scaleway | 付费对象存储，费用见 [存储定价](https://www.scaleway.com/en/pricing/storage/)。 |

仓库规模显著增长后，可按 [受控启用流程](../../docs/backup.md#受控启用与预算核对) 记录单次备份与分片检查前后的控制台增量并校准参数。
