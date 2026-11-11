# 配置、脚本与状态

`flake.nix` 注册主机、开发环境和检查。找到一项行为时，先看由谁选择它，再看模块如何装配服务，最后跟到服务执行的脚本。

| 位置 | 负责的内容 |
| --- | --- |
| `hosts/<名称>/` | 硬件、启动、用户与版本、凭据位置、实际备份目标及主机特定策略 |
| `profiles/laptop/` | 桌面与工具组合、持久状态清单、备份范围、共同网络默认值 |
| `modules/` | 能力选项、NixOS 服务和软件装配 |
| `home/` | 随系统激活的用户配置，包括 CLI、应用、桌面与状态栏 |
| `lib/` | 策略组合、凭据字段绑定和共享服务设置 |
| `nix/` | 包定制、工具包装、检查和缓存清单 |
| `scripts/` | 系统服务及本地维护命令的运行逻辑 |
| `.github/workflows/` | GitHub 事件、步骤、权限、runner 准备与释放 |
| `.github/ci/` | 构建事件统计、资源采集、缓存筛选和候选提交处理 |
| `tests/` | 合成配置、行为与进程检查、原生 NixOS VM 场景 |
| `tools/vm-test-mcp/` | 可选远端执行客户端和可移除的兼容处理 |

## 配置归属

每台机器在主机目录声明用户名、UID、系统与 Home Manager 的 `stateVersion`、磁盘和密钥位置，并在 flake 中注册。profile 组合多台机器可以共用的选择。测试使用独立的合成 laptop，不依赖某台机器的硬件或真实密文。

Home Manager 使用系统的 `pkgs`，通过 NixOS 模块构建和激活用户配置。系统闭包已经包含用户激活产物，维护入口统一见[主机维护](maintenance.md)。

能力通过 `site.*.enable` 和原生 NixOS 选项选择。DNS、sing-box 和 Lockdown 可分别组合；Tailscale 使用原生模块；Sway、i3、Plasma 可分别选择。非自由软件的许可声明与选择它的模块放在一起，Home Manager 与系统共用这项策略。

## 从服务找到脚本

| 行为 | 配置入口 | 运行逻辑 |
| --- | --- | --- |
| 备份 | [服务与策略](../modules/services/backup.nix) | [Restic 作业、调度、状态与通知](../scripts/backup) |
| 网络切换 | [策略模块](../modules/network/policy.nix) | [生成、应用与回退](../scripts/network/runtime_policy.py) |
| 桌面电源菜单 | [桌面配置](../home/desktop.nix) | [进程提醒与电源操作](../scripts/desktop/power.py) |
| 壁纸 | [会话与定时任务](../modules/desktop/wallpaper.nix) | [恢复、轮换与下载](../scripts/desktop/wallpaper.py) |
| SSH/GPG | [系统和用户服务](../modules/core/cli.nix) | [公钥发布与身份注册](../scripts/secrets/identity.py) |
| CI | [工作流](../.github/workflows) | [构建统计、发布与更新](../.github/ci) |

脚本选 Python 是为了文件状态、结构化数据和进程协调；简单线性调用留在 shell 或 Nix 服务定义。网络规则中的 Go 辅助程序使用实际 RE2 语义，避免以另一种正则实现近似判断规则。

## 持久状态

`site.storage.persistRoot` 指定 Nix store 外的持久挂载位置，默认 `/persist`。模块据此派生 SOPS key、Restic 源和本机策略路径。改变位置需要同时处理磁盘挂载与已有数据，不能只改一个选项后切换。

laptop profile 的持久清单独立于功能开关。禁用应用后数据仍可通过原路径访问，必要的状态所有者也继续存在。impermanence 使用 bind mount 保存应用可写目录；需要原子替换的 Plasma 单文件通过持久链接管理。已有目录权限和原生服务的 `StateDirectory` 设置都参与实际权限结果。

系统声明、应用可写偏好和恢复资料各有入口，详见[本机配置](local-state.md)。持久化清单覆盖正常使用所需的状态和缓存；备份只选择[备份范围](backup.md)中的资料。现有仓库状态、调度记录和通知队列随持久根保留。

凭据由 SOPS 密文在目标机运行时解密，模块接收文件路径。`lib/credentials.nix` 统一 laptop 的字段绑定，host 提供密文目录、用户名和备份目标；Wi-Fi profile 等机器选择仍由 host 声明。测试通过同一绑定使用合成资料。

证书由最终 `security.pki.caBundle` 管理，网络服务和通知镜像使用同一信任来源。公共构建及发布范围见[缓存](cache.md)。

## 权限边界

桌面应用的文件访问范围集中在[桌面指南](desktop.md#应用隔离)。Firejail 保护处理外部内容的应用，复用上游 profile 并保留浏览器的原生沙箱。VS Code Dev Containers 和 Kitty 需要完整开发环境，由常规桌面入口运行。

后台桌面服务以 systemd 隔离各自的 home 状态和运行目录。dnsdist、dnsproxy、DNS Collector、oranc 处理网络输入，使用独立身份、只读系统及设备/能力限制；LuaJIT 所需的内存执行能力仅对 dnsdist 保留。整机接管由 Mullvad 完成，sing-box 通过用户态 WireGuard endpoint 接收流量，并用 FakeIP 恢复域名。引擎以专用用户运行，保留物理出口绑定及可选原生 endpoint 所需的网络能力；配置生成先在无网络、只读输入的独立沙箱完成，发布进程仅控制声明的服务。

Restic 按仓库分离可写状态与 cache，源目录只读。Apprise/Bark 使用各自的 gVisor 容器和运行时凭据，Waydroid 使用上游 LXC 边界。常见基础服务继续使用 NixOS 上游单元定义。

服务限制由 systemd 表达，共享设置位于[系统服务隔离](../lib/service-hardening.nix)和[桌面服务隔离](../lib/desktop-service-hardening.nix)，具体权限由服务模块选择。

图形用户服务仍使用会话 socket，包括用户 D-Bus 和窗口管理器 IPC；这些接口保留了会话级权限，文件系统限制约束的是进程的直接访问。X11 还允许较广泛的窗口与输入访问。因此，这些服务与桌面会话处于同一信任范围。Firejail 应用另外使用各自的 D-Bus 规则；文件选择器可见范围由其文件系统视图决定。

[基础模块](../modules/core/base.nix)将 io_uring 限于具有 `CAP_SYS_ADMIN` 的进程，减少桌面进程可达的内核接口。普通用户及受限应用需要使用其他 I/O 接口。
