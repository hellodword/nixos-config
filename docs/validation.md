# 开发与验证

构建和测试使用 `flake.lock` 中的依赖。测试源按执行环境组织，使用合成账户、凭据、仓库和网络服务。

## 选择检查入口

| flake 检查 | 覆盖的行为 | 实现位置 |
| --- | --- | --- |
| `unit` | 路径选择与仓库/策略状态、策略切换/恢复、显示布局；真实 Restic 三仓库备份和完整恢复，独立频率、手动额外执行与持久重试，远端检查请求量、损坏检测、信号中断和锁恢复；公钥推导、声明身份注册及签名、GPG 资料补齐、Git 验签与换钥期间的新旧身份共存 | `tests/unit/`、`tests/integration/backup.py`、`secrets.py` |
| `network` | 真实 dnsdist/dnsproxy/sing-box、DoT/HTTP2 DoH、独立 DNS/显式代理及组合、文件顺序/规则集/逻辑匹配与路由一致性、TLS/ECS/缓存、完整响应日志和代理故障 | `tests/integration/dns.py`、`network.py` |
| `configuration` | 合成 SOPS 密文经过真实主机字段与 Wi-Fi/身份绑定；完整主机、网络、Tailscale 及桌面/应用能力组合，验证有效服务、会话、禁用能力后的持久清单与所有权，求值系统闭包；临时 Git 仓库验证持续备份推送 | `tests/configuration.nix` |
| `desktop` | 生产 Fontconfig 字形匹配、混排宽度与图标/emoji；原生 Sway/i3 配置验证 | `tests/desktop.nix`、`tests/integration/desktop.py` |
| `vm-backup` | 真实 Restic 三仓库、上海时间窗口、故障重试、路径边界、取得真实仓库锁后的正常中断及后端无响应时的关机、重启解锁与恢复；gVisor 内 Apprise/Bark 中文通知、官方 TLS 模拟上游、凭据隔离和跨重启的最新结果补发 | `tests/vm/backup.nix` |
| `vm-network` | 本机与 Tailscale 出口客户端的持续双栈流量、DNS、NAT 穿透与 DERP；独立 WireGuard/OpenVPN 接口传输、策略更新及就绪失败恢复、服务故障、日志轮转、断网及重启恢复；三种网络能力组合下的通知、普通 Docker/Compose 的 DNS 与出口、服务名互通及端口发布、网络重建、prune 与 Docker 重启 | `tests/vm/network.nix` |
| `vm-desktop` | SDDM 三会话登录、原生与 Rofi 注销、重新登录；电源菜单对虚拟机和备份任务的阻挡及正常重启/关机；空闲与手动锁屏、显示布局变化后的解锁、Plymouth 加密启动；标签布局、Waybar、截图剪贴板、输入法、KWallet、壁纸，以及显示布局、NetworkManager 连接和 GPG 身份操作的重启恢复 | `tests/vm/desktop.nix` |
| `vm-applications` | 默认 1920×1080 下，三会话中的 Firefox、VS Code Dev Containers、Bitwarden Desktop、Kitty、Rofi 基础操作，以及真实应用运行时的注销提醒 | `tests/vm/applications.nix`、`applications.py` |
| `e2e` | 完整 laptop2 系统与 ubuntu Home Manager 激活产物，以及配置、进程集成、字体与桌面配置、备份/网络/桌面/应用 VM 的必需结果 | `nix/checks.nix` |

```sh
nix build --no-link .#checks.x86_64-linux.unit .#checks.x86_64-linux.network .#checks.x86_64-linux.configuration
```

开发时可先运行较快的单元场景或单个集成入口：

```sh
nix develop --command python3 -m unittest discover -s tests/unit -t . -v
nix develop --command python3 -m tests.integration.backup -v
nix develop --command python3 -m tests.integration.secrets -v
nix develop --command python3 -m tests.integration.cache
```

缓存检查通过临时 OCI registry 和 oranc 验证可再分发路径筛选、直接签名发布，以及在受限依赖已准备好的情况下恢复公共输出，详见[缓存指南](cache.md)。桌面变更另运行 `nix build --no-link .#checks.x86_64-linux.desktop`。

验证范围按实际改动选择既有入口：声明式桌面配置和字体使用 `configuration`、`desktop` 及生产系统/Home Manager 构建；登录界面、会话生命周期和壁纸调度使用完整 `vm-desktop`。应用启动、隔离或开发容器行为涉及 `vm-applications`；依赖升级和跨子系统验收使用 `e2e`。

## CI

升级门禁是独立的 Nix 检查，可由 CI 在候选工作副本中调用：

```sh
nix flake update nixpkgs home-manager plasma-manager
nix build --no-link --no-update-lock-file .#checks.x86_64-linux.e2e
```

候选配置通过检查后再提交、合并。完整系统构建使用正式 secrets 默认路径和绑定，构建不解密 SOPS；行为场景使用独立的合成凭据。工作流定期更新指定输入，验收后提交锁文件、重新构建正式 revision，并通过 PR 将相同提交快进合并。触发方式、更新清单和首次启用步骤见 [CI 指南](ci.md)。其他分支的手动运行只负责验收。

运行节点需要 x86_64 Linux、KVM 和相应的 Nix 构建器系统特性。应用 VM 依次启动，每台配置 6 GiB 内存和 2 个 vCPU。

应用场景使用生产 Home Manager、桌面、应用和 Docker 模块。合成用户通过 SDDM 登录 Sway、i3 和 Plasma，在默认 1920×1080 分辨率下完成以下基础操作：

| 应用 | 可观察的验收结果 |
| --- | --- |
| Kitty、Rofi | 两个 WM 的 Super+D 选择 Kitty，使用拼音输入中文并执行命令写出文件；Super+Shift+D 执行命令；Plasma 中同样验证 Kitty 中文输入 |
| Firefox | 打开声明式默认 profile，加载本地网页，在页面输入框中使用拼音输入中文；电源菜单显示 Firefox 注销提醒 |
| VS Code Dev Containers | 由已配置的扩展进入容器工作区，在编辑器中使用拼音输入中文并保存；在内置终端中执行中文命令并检查结果；电源菜单显示 VS Code 注销提醒 |
| Bitwarden Desktop | 使用本地 HTTPS Vaultwarden 和合成账户登录，在密码库搜索框中使用拼音输入中文；密码库运行期间，电源菜单提示退出 Bitwarden |

`tests/fixtures/applications/` 提供本地站点和开发容器，VS Code Server 来自 `vscode.vscodeServer`。中文输入通过 VM 键盘和 Fcitx5 完成。桌面与应用场景共用 `tests/vm/gui.py`，同一 VM 的键鼠输入、截图及 monitor 操作串行执行；窗口等待和图像转换受截止时间限制。活动维持线程先结束，再关闭 VM；正常关机最多等待 120 秒，超时则释放该测试 VM 并报告失败，收尾错误与原始错误一并保留。测试输出保留按应用、会话命名的日志、截图和结果。

`.github/workflows/ci.yml` 在 `master` push、定期更新或手动触发时调用 `scripts/ci.sh`。先运行格式、ShellCheck、actionlint 和缓存集成，再准备不公开发布的依赖，构建完整 `e2e` 与两个开发 shell。没有锁文件变化的自动更新不运行昂贵检查。Nix 同时只调度一个构建任务，VM 结果可按哈希从签名缓存复用；镜像及 action 版本由 workflow 自身固定。

该脚本为 Docker 内的嵌套构建设置 `sandbox = false`；本地开发直接使用各项检查与主机 daemon 的设置。

## VM 与设备验收

本机具备 KVM 时，可直接构建对应的 `checks.x86_64-linux.vm-*`。远端使用已准备的 vm-test-mcp，客户端来自锁定的 `vm-test-tools` 输入：

```sh
nix develop .#vm --command vm-test-submit --help
```

项目检查不依赖执行器协议；本地与 CI 消费相同的 Nix 测试定义，传输和资源管理由所选执行工具负责。

网络 VM 在目标端记录本机及 exit-node 客户端的实际出口，持续覆盖 direct/代理 × TCP/UDP × IPv4/IPv6；从默认 IPv4 启动，验证 HTTPS、运行时启用/关闭 IPv6，以及重启后回到声明式默认值。主机、普通 Docker/Compose 和出口客户端显式指定外部 DNS 地址的 TCP/UDP 查询均走共享解析。私网、Tailnet 和默认/自建 Docker bridge 访问宿主服务，公网访问按发布前的宿主端口判断；UDP 通配监听验证回复源地址。HTTP/SOCKS 与 SSH ProxyCommand 使用实际 mixed 入口，KDE Connect 使用合成设备发现、配对和传输文件。Tailscale 场景从已有 `shields-up=true` 的身份应用声明，然后验证客户端真实出口 HTTP 和 DNS。通知使用真实 Apprise API、Bark 和 runsc，由独立节点模拟官方 TLS 服务，记录合成推送。

备份 VM 使用受控时间验证首次等待、超期、真实失败及成功后的健康状态，覆盖窗口调度、持锁中断、后端不可用时有界关机以及重启后锁恢复。网络 VM 验证完整 DNS 正文和 debug 日志进入独立命名空间，系统记录、轮转和跨重启历史分别保留。桌面 VM 通过 SDDM 登录、正常注销再登录，检查网络托盘、KWallet、Safe Eyes 及用户设置的恢复；模拟无线设备用于声明式与本机连接的验证。Sway 通过 wdisplays 的原生 Apply 动作保存单屏和双屏配置，再比较拔屏、重新登录和重启后的实际启用输出、位置、分辨率与缩放。应用 VM 保存 Kitty 初始提示符以及 Kitty/Firefox 的拼音候选截图，并验证中文提交结果。

设备验收覆盖真实 SOPS 解密、AP 认证、外接屏幕/合盖、Secure Boot、正常注销/锁屏，以及云端权限和资料恢复。

电源菜单场景通过实际 Rofi 键盘操作选择动作，以真实 QEMU 进程和合成 systemd 备份服务覆盖其他用户的虚拟机、排队任务和执行中任务，随后完成原生会话退出及系统电源操作。应用 VM 在真实 Firejail/Nix/Electron 启动链上验证提醒。锁屏覆盖空闲、手动以及旋转屏幕或多输出布局，通过键盘输入合成用户密码解锁并保存画面。竖屏菜单的文字识别按显示方向转正，截图产物保留 QEMU 的原始画面。PipeWire 的检查跨越注销和重新登录，读取 boot 内的 coredump 记录。

加密启动场景将合成测试系统迁入 VM 专属空磁盘，使用合成口令安装带 Breeze 的启动代次，经图形控制台输入 LUKS 口令后登录 SDDM/Sway。图形解锁截图属于测试产物；实际 i915 显示和 Secure Boot 签名链仍在 laptop2 验收。

壁纸场景使用本地 HTTPS 图片源，通过受控响应延迟、请求记录和实际背景像素，验证先恢复本地图片、到期下载、成功后的新图切换、无新图或离线时保留画面，以及本地轮换、配置重载、注销和重启后的状态恢复。测试调整合成用户的持久下载时间，经过生产 timer 与服务执行到期任务。KWallet 使用合成 Secret Service 条目的存取和重启后读取来验收解锁。

GPG 身份场景通过生产发布器和用户注册服务连接本机 SSH 服务，覆盖缺少一个子密钥时其余身份可用、补齐后的自动启用、发布新代次后新旧身份共存、确认连接后的手动停用，以及重新登录和重启后的连接与 Git 验签。本机额外身份使用原生注册，验证其持续可用；声明身份由生产注册逻辑启用。真实智能卡的插拔、PIN 与签名在设备上验收。

桌面 VM 保留 SDDM 登录界面和实际 Kitty 字体样张。Kitty 样张覆盖中英网格、编程连字、文字/emoji 表示及肤色、ZWJ、国旗、键帽组合；`desktop` 的 Fontconfig/Pango 检查负责字体选择和通用文本度量，不能替代终端自身的显示验证。

音频、双电池、真实外屏 DPI 与触控板手感在 laptop2 验收：播放媒体、进行浏览器通话并切换麦克风/耳机；检查虚拟机客体音频；逐块外屏保存、拔插并重新登录；确认轻触点击、双指滚动和打字抑制。VM 可验证服务和配置生命周期，不能替代这些硬件行为。
