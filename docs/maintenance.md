# 主机维护

主机在 `flake.nix` 的 `nixosConfigurations` 中注册。以下命令在仓库根目录运行，先指定目标主机：

```sh
host=laptop2  # 换成要维护的主机
nix eval --json .#nixosConfigurations --apply builtins.attrNames
```

## 日常构建、切换与重启升级

```sh
nix build --out-link result ".#nixosConfigurations.${host}.config.system.build.toplevel"
sudo nixos-rebuild switch --flake ".#${host}"
```

系统闭包同时包含 NixOS 服务与 Home Manager 用户配置；构建阶段不解密 SOPS 密文，凭据在目标机激活时由 `sops-nix` 解密（见 [凭据指南](secrets.md)）。

涉及内核、initrd、持久挂载、物理网络或 Lockdown 组合调整时，安装下次启动代次并重启切换：

```sh
sudo nixos-rebuild boot --flake ".#${host}"
sudo bootctl list
```

重启后检查 `sudo sbctl status`、`systemctl --failed`、`systemctl --user --failed`、`sudo network-ipv6 status` 与 `backup-status`。构建缓存的持久配置见 [构建缓存](cache.md)。

## Flake 输入与子 Flake 依赖更新

根仓库声明 **20 个 Flake 输入**，其中 `infra` 指向仓内公共基础设施子 flake `./infra`（`infra/flake.lock` 锁定公共 `nixpkgs` 与独立依赖锁的 `oranc`），主包集 `nixpkgs` 跟随 `infra/nixpkgs`。按更新节奏与影响边界分为三组（自动更新目标与工作流定义见 [nix/ci.nix](../nix/ci.nix) 与 [update.yml](../.github/workflows/update.yml)）：

| 分组 | 包含输入与锁文件 | 更新方式 |
| --- | --- | --- |
| `laptop` 自动更新（`infra/flake.lock` + `flake.lock`） | `infra` 内的 `nixpkgs`，以及根仓的 `infra`、`home-manager`、`plasma-manager`、`nixos-hardware`、`nix-index-database`、`arkenfox-userjs`、`catppuccin-fcitx5`、`reproducible-violentmonkey`、`sing-box-geosite`、`sing-box-geoip` | 定时或手动运行 `Update flake inputs`（`laptop`）；本地运行 `nix flake update nixpkgs --flake ./infra && nix flake update infra home-manager plasma-manager` |
| `remote` 自动更新（仅根 `flake.lock`） | `nixpkgs-remote`、`colmena`、`cloudflare-ips-v4`、`cloudflare-ips-v6` | 定时或手动运行 `Update flake inputs`（`remote`），推进 VPS 包集、部署器与 Cloudflare 回源白名单 |
| 按需手动更新 | `infra` 内的 `oranc`，以及根仓的 `disko`、`impermanence`、`lanzaboote`、`sops-nix`、`agents-misc` | `oranc` 执行 `nix flake update oranc --flake ./infra && nix flake update infra`；其余根输入执行 `nix flake update <名称>` 并做针对性验证 |

锁文件仅通过 `nix flake lock` / `nix flake update` 更新（更新子目录 flake 时使用 `./infra` 或 `"git+file://$PWD?dir=infra"`）。本地推进依赖后，按 [验证指南](validation.md#配置求值) 执行对应范围的清单求值与行为检查：

```sh
nix flake update catppuccin-fcitx5
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
```

## 回退与激活故障处理

可从 UEFI 启动菜单选择上一代次，或在运行中立即回退：

```sh
sudo nixos-rebuild switch --rollback
```

系统回退切换程序与服务声明，`/persist` 中的应用数据库、钱包与本机偏好保持当前状态；如需回退应用数据，先将备份快照恢复到独立目录审阅（见 [备份与恢复](backup.md)）。

排查 Home Manager 激活冲突：

```sh
login_user=$(id -un)
systemctl status "home-manager-${login_user}.service"
journalctl -b -u "home-manager-${login_user}.service"
```

若日志指出普通文件阻挡了声明式链接，先退出对应应用，用 `findmnt -T <路径>` 确认挂载归属，将该文件备份移开或合并至本机可写入口，再执行 `sudo systemctl restart "home-manager-${login_user}.service"`。

## 裸机安装与离线引导恢复

使用 tmpfs 根与持久化子卷的笔记本按以下顺序完成裸机初始化或灾难恢复（完整命令实例见 [laptop2 裸机安装与恢复](../hosts/laptop2/README.md#裸机安装与离线引导恢复)）：

1. **LUKS2 分区与口令注册**：若 `disko.nix` 使用临时密钥文件（如 `/tmp/crypt.key`）建表，先在安装介质内存生成临时密钥并执行 `system.build.diskoScript`，随后用 `cryptsetup luksAddKey` 注册开机交互口令，并用 `luksRemoveKey` 移除临时密钥槽与明文文件。
2. **Secure Boot 身份准备**：创建 `0700` 权限的 `/mnt/persist/etc/secureboot`（恢复离线备份的密钥对，或在 UEFI Setup Mode 下通过 `sbctl create-keys` 初始化并在进入系统后 `sbctl enroll-keys --microsoft`），确保 `nixos-install` 期间 Lanzaboote 可签发 UKI。
3. **离线引导凭据与数据恢复**：
   - 将离线保存的 SOPS age 私钥安装到 `/mnt/persist/var/lib/sops-nix/keys.txt`（`root:root`、`0600`），供首次启动解密登录密码、Wi-Fi、备份与身份密文；
   - 将初始代理节点配置安装到 `/mnt/persist/usr/local/etc/sing-box/outbounds.json`（`root:root`、`0600`），使 Lockdown 与代理链路在首次启动即可连通；
   - 使用离线 Restic 凭据将最新快照恢复至临时目录校验后，按原属主与权限拷回 `/mnt/persist`（含 `/etc/ssh`、`tailscale`、`~/.gnupg`、KWallet、Fcitx5 及核心应用数据）。
4. **系统安装与启动验收**：运行 `sudo nixos-install --no-root-passwd --flake ".#${host}"`，重启后核对 `sudo sbctl status`、`systemctl --failed`、`sudo network-policy check`、`ssh-add -L` 与 `backup-status`。

## Docker 维护

[容器模块](../modules/services/containers.nix) 启用 `local` 轮转日志驱动、`live-restore`、每周自动 `docker-prune`（清理停止的容器、未使用网络、悬空镜像与构建缓存，保留命名卷及带 `org.nixos-config.service` 标签的通知服务资源），以及每日 `site-devcontainer-cache-prune.timer`。后者以普通用户身份调用 `devcontainer-cache-prune`（[scripts/containers/prune_caches.py](../scripts/containers/prune_caches.py)），从本地 `devcontainers-dev:latest` 镜像的 `devcontainers.nix.cache-layout` Label 读取缓存目录契约，在无网络、降权隔离容器内执行 `devcontainer-runtime prune-caches`（无活动容器挂载 `~/.local/state/devcontainers/cache` 时自动启用 `--idle` 深度回收，本地尚未拉取镜像时跳过）：

```sh
docker system df
systemctl list-timers docker-prune.timer site-devcontainer-cache-prune.timer
journalctl -u docker-prune.service -u site-devcontainer-cache-prune.service -n 50 --no-pager
devcontainer-cache-prune --dry-run
```

## 增加主机

1. 在 `hosts/<名称>/` 声明硬件配置、Disko 分区、启动方案、主机名、用户名、UID，以及系统与 Home Manager 的 `stateVersion`。
2. 导入 `profiles/laptop`（或所需功能模块，无头服务器可直接导入 `./modules` 并保持 `site.home.enable = false`），按实际预算设置备份目标与网络公告。
3. 在 `.sops.yaml` 注册新主机的 age 公钥规则，准备 `hosts/<名称>/secrets/*.sops.yaml`，并通过 `lib/credentials.nix` 绑定运行时凭据。
4. 在 `flake.nix` 的 `nixosConfigurations` 注册主机，完成清单求值与构建验证；如需纳入托管 CI，同步更新 `.github/workflows/ci.yml` 矩阵。
