# 架构与维护入口

`flake.nix` 锁定输入并提供系统、开发环境和检查入口。`hosts/laptop2/` 组合硬件与 `profiles/laptop/`；模块提供能力，profile 选择能力和默认策略。

| 位置 | 职责 |
| --- | --- |
| `hosts/laptop2/` | 现有磁盘、启动、硬件、功能组合与主机凭据绑定 |
| `profiles/laptop/` | 功能组合、持久状态清单、备份范围和默认分流规则 |
| `modules/core/` | 用户、存储根、Home Manager 接入与 CLI 系统服务 |
| `modules/network/` | DNS、sing-box、Lockdown、Tailscale、Docker 桥接网络与 Wi-Fi |
| `modules/desktop/` | 会话、显示管理、门户、字体、应用和生产力工具 |
| `modules/services/` | Restic、本地通知、容器、虚拟机、Android 和 OCI cache |
| `home/` | Home Manager 用户配置：CLI、应用、桌面与状态栏 |
| `lib/` | 纯策略与数据组合 |
| `nix/` | 包装工具、包定制与检查装配 |
| `scripts/` | 服务运行逻辑和维护命令 |
| `tests/` | 配置矩阵、行为测试、进程集成及 VM 场景 |

## 配置与状态所有权

Home Manager 使用系统的 `pkgs`，通过 `useUserPackages` 安装用户软件。Firefox 的搜索设置、VS Code 扩展、SSH/Git 和桌面配置由各自原生模块生成。NixOS impermanence 管理系统与用户的持久挂载；应用可写目录使用内核 bind mount，支持原子替换的 Plasma 单文件使用持久化链接。

Home Manager 激活失败不会阻止图形登录。i3、Sway 及其通知和状态栏服务直接读取构建出的配置；用户目录存在冲突时，可以先进入会话，再查看 `home-manager-ubuntu.service` 并处理具体路径。冲突文件由用户保存并按应用入口合并。

SSH/Git 覆盖、Wi-Fi、显示方案和输入法学习记录由应用管理。systemd 用户 tmpfiles 以 `C` 规则初始化缺失的 GTK 2 配置，并为 kanshi 创建空的可写配置文件，日常修改入口见[本机配置](local-state.md)。SSH、Git/GPG 基线使用分组 SOPS YAML 中的字符串字段，运行时由 sops-nix 交给消费者。NetworkManager 原生支持声明式连接与本机连接，凭据通过运行时环境文件提供。

## 持久根与安装约定

`site.storage.persistRoot` 是绝对、位于 Nix store 外的路径，默认 `/persist`，laptop2 在主机配置中显式选择它。模块通过 `config.site.storage.persistRoot` 派生持久化映射、SOPS key、Restic 源目录和运行时策略位置；新增主机可以覆盖该选项。

此选项表示挂载位置。已有 laptop2 的物理分区、LUKS、Btrfs 子卷名称、swap 和 Secure Boot 身份由主机文件保留。改变挂载位置仍需单独安排已有数据和启动配置的迁移。个人用户 UID、系统与 Home Manager `stateVersion` 均沿用现有安装。

`profiles/laptop/persistence.nix` 集中列出持久状态，独立于服务 enable。禁用应用后，数据仍通过原路径可见；sing-box 的状态所有者也随该清单保留。SSH 主机密钥按 `services.openssh.hostKeys` 逐个持久化，SSH 配置由 NixOS 生成。impermanence 对已有持久目录沿用盘上权限，声明的 mode 用于创建目录。NixOS 用户激活管理 home 本身的所有权和 0700 权限；服务状态同时遵循各自原生 `StateDirectory` 的权限设置。SSH/GPG 与密钥状态使用受限权限，应用可写配置保持原生文件格式。

持久化与备份是两个清单：持久化覆盖应用正常使用所需的状态、开发目录和缓存；Restic 只选择[备份策略](backup.md)列出的资料。镜像、卷及历史容器目录的后续清理由数据所有者单独安排。

## 功能与许可

能力使用 `site.core`、`site.cli`、`site.desktop`、`site.apps`、`site.connections`、`site.backup`、`site.containers`、`site.virtualbox`、`site.android.*`、`site.productivity` 和 `site.cache`、`site.notifications` 的 `enable`。网络拆为 DNS、sing-box 和 Lockdown；Tailscale 使用原生 `services.tailscale.enable`。桌面可分别选择 Sway、i3、Plasma。

需接受非自由软件许可的功能，在自身模块中声明原生 `nixpkgs.config.allowUnfreePackages` 包名列表。Home Manager 与系统共享这项许可策略，包的选择和许可入口放在一起维护。

## 运行逻辑

| 目录 | 职责 |
| --- | --- |
| `scripts/network/` | 共享 route 编译、代理节点合并、DNS 日志、策略发布、出口观察、Docker 本地路由同步与 Lockdown 控制 |
| `scripts/backup/` | 文件选择、Restic 调度、仓库通路检查、结果通知和健康状态 |
| `scripts/notifications/` | 容器内 API 初始化和本地发送客户端 |
| `scripts/secrets/identity.py` | 在隔离公钥环中推导并发布 SSH/Git 文件 |
| `scripts/desktop/` | 显示布局、截图、Tailscale 状态、健康通知 |
| `scripts/cli/` | 电台播放和容器镜像拉取 |
| `scripts/ci.sh` | 现有 CI 检查入口 |

DNS 与 sing-box 分别编译共享 route 子集；Mullvad 负责流量接管和 Lockdown，sing-box 的本地 WireGuard endpoint 接收后执行分流。Tailscale 传输和出口客户端流量各自按策略处理，拓扑、规则优先级和运行命令见[网络](network.md)。

公开源码与 SOPS 密文放在同一仓库；公开构建使用合成资料与明确的[缓存范围](cache.md)。

主机身份和服务凭据集中在 `hosts/laptop2/secrets.nix`，填写方式见[主机凭据](secrets.md)。显示管理由 `modules/desktop/displays.nix` 按会话选项启用。[本地通知](notifications.md)使用独立 gVisor 容器，发送入口是受 Unix 权限控制的 socket。

证书由 NixOS 最终 `security.pki.caBundle` 管理；sing-box 和 Tailscale 各自随 bundle 更新重启，通知镜像也使用同一信任源。
