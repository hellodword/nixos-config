# 开发与验证

构建和测试使用 `flake.lock` 中的依赖。测试源按执行环境组织，使用合成账户、凭据、仓库和网络服务。

## 选择检查入口

| flake 检查 | 覆盖的行为 | 实现位置 |
| --- | --- | --- |
| `unit` | 路径选择与仓库/策略状态、策略切换/恢复、显示布局；真实 Restic 三仓库备份和完整恢复；公钥推导、手动 agent 注册及签名、Git 验签与子密钥轮换 | `tests/unit/`、`tests/integration/backup.py`、`secrets.py` |
| `network` | 真实 dnsdist/dnsproxy/sing-box、DoT/HTTP2 DoH、独立 DNS/显式代理及组合、文件顺序/规则集/逻辑匹配与路由一致性、TLS/ECS/缓存、完整响应日志和代理故障 | `tests/integration/dns.py`、`network.py` |
| `configuration` | 合成 SOPS 密文经过真实主机字段与 Wi-Fi/身份绑定；完整主机、网络、Tailscale 及桌面/应用能力组合，验证有效服务、会话、禁用能力后的持久清单与所有权，求值系统闭包；临时 Git 仓库验证持续备份推送 | `tests/configuration.nix` |
| `desktop` | 生产 Fontconfig 字形匹配、混排宽度与图标/emoji；原生 Sway/i3 配置验证 | `tests/desktop.nix`、`tests/integration/desktop.py` |
| `vm-backup` | 真实 Restic 三仓库、上海时间窗口、故障重试、路径边界、后端无响应时的关机与恢复；gVisor 内 Apprise/Bark 中文通知、官方 TLS 模拟上游、凭据隔离和跨重启的最新结果补发 | `tests/vm/backup.nix` |
| `vm-network` | 本机与 Tailscale 出口客户端的持续双栈流量、DNS、NAT 穿透与 DERP；独立 WireGuard/OpenVPN 接口传输、策略更新及就绪失败恢复、服务故障、日志轮转、断网及重启恢复；三种网络能力组合下的通知、普通 Docker/Compose 的 DNS 与出口、服务名互通及端口发布、网络重建、prune 与 Docker 重启 | `tests/vm/network.nix` |
| `vm-desktop` | SDDM 三会话登录/正常注销/重新登录；标签布局、Waybar 悬浮详情和月历、空闲抑制与锁屏、截图剪贴板、输入法、KWallet；显示布局、NetworkManager 连接及 GPG 身份操作的重启恢复 | `tests/vm/desktop.nix` |
| `vm-applications` | 默认 1920×1080 下，三会话中的 Firefox、VS Code Dev Containers、Bitwarden Desktop、Kitty、Rofi 基础可用性 | `tests/vm/applications.nix`、`applications.py` |
| `e2e` | 完整 laptop2 系统与 ubuntu Home Manager 激活产物，以及配置、进程集成、字体与桌面配置、备份/网络/桌面/应用 VM 的必需结果 | `nix/checks.nix` |

```sh
nix build --no-link .#checks.x86_64-linux.unit .#checks.x86_64-linux.network .#checks.x86_64-linux.configuration
```

开发时可先运行较快的单元场景或单个集成入口：

```sh
nix develop --command python3 -m unittest discover -s tests/unit -t . -v
nix develop --command python3 -m tests.integration.backup -v
nix develop --command python3 -m tests.integration.cache
```

缓存检查通过临时 OCI registry 和 oranc 完成签名闭包的发布、读取与恢复，详见[缓存指南](cache.md)。桌面变更另运行 `nix build --no-link .#checks.x86_64-linux.desktop`。

## CI

升级门禁是独立的 Nix 检查，可由 CI 在候选工作副本中调用：

```sh
nix flake update nixpkgs home-manager plasma-manager
nix build --no-link --no-update-lock-file .#checks.x86_64-linux.e2e
```

候选配置通过检查后再提交、合并。完整系统构建使用正式 secrets 默认路径和绑定，构建不解密 SOPS；行为场景使用独立的合成凭据。仓库工作流执行验收，依赖更新、提交与合并由维护者操作；在候选分支上手动运行 workflow 可在合并前取得结果。

运行节点需要 x86_64 Linux、KVM 和相应的 Nix 构建器系统特性。应用 VM 依次启动，每台配置 6 GiB 内存和 2 个 vCPU。

应用场景使用生产 Home Manager、桌面、应用和 Docker 模块。合成用户通过 SDDM 登录 Sway、i3 和 Plasma，在默认 1920×1080 分辨率下完成以下基础操作：

| 应用 | 可观察的验收结果 |
| --- | --- |
| Kitty、Rofi | 两个 WM 的 Super+D 选择 Kitty，使用拼音输入中文并执行命令写出文件；Super+Shift+D 执行命令；Plasma 中同样验证 Kitty 中文输入 |
| Firefox | 打开声明式默认 profile，加载本地网页，在页面输入框中使用拼音输入中文 |
| VS Code Dev Containers | 由已配置的扩展进入容器工作区，在编辑器中使用拼音输入中文并保存；在内置终端中输入中文、执行命令并检查容器内结果 |
| Bitwarden Desktop | 使用本地 HTTPS Vaultwarden 和合成账户登录，在密码库搜索框中使用拼音输入中文 |

`tests/fixtures/applications/` 提供本地站点和开发容器，VS Code Server 来自 `vscode.vscodeServer`。中文输入通过 VM 键盘和 Fcitx5 完成。桌面与应用场景共用 `tests/vm/gui.py`，同一 VM 的键鼠输入、截图及 monitor 操作串行执行；窗口等待和图像转换受截止时间限制。活动维持线程先结束，再关闭 VM；正常关机最多等待 120 秒，超时则释放该测试 VM 并报告失败，收尾错误与原始错误一并保留。测试输出保留按应用、会话命名的日志、截图和结果。

`.github/workflows/check.yml` 在 `master` push 或手动触发时调用 `scripts/ci.sh`。配置 KVM 后直接运行完整 `e2e`，再运行 Nix 格式、ShellCheck、actionlint 和本地缓存集成。Nix 同时只调度一个构建任务，避免多组 VM 争用内存。镜像及 action 版本由 workflow 自身固定。

该脚本为 Docker 内的嵌套构建设置 `sandbox = false`；本地开发直接使用各项检查与主机 daemon 的设置。

## VM 与设备验收

本机具备 KVM 时，可直接构建对应的 `checks.x86_64-linux.vm-*`。远端使用已准备的 vm-test-mcp，客户端来自锁定的 `vm-test-tools` 输入：

```sh
nix develop .#vm --command vm-test-submit --help
```

项目检查不依赖执行器协议；本地与 CI 消费相同的 Nix 测试定义，传输和资源管理由所选执行工具负责。

网络 VM 在目标端记录本机及 exit-node 客户端的实际出口，持续覆盖 direct/代理 × TCP/UDP × IPv4/IPv6。通知使用真实 Apprise API、Bark 和 runsc，由独立节点模拟官方 TLS 服务，记录合成推送。桌面 VM 通过 SDDM 登录、正常注销再登录，检查 KWallet、Safe Eyes 及用户设置的恢复；模拟无线设备用于声明式与本机连接的验证。Sway 通过 wdisplays 的原生 Apply 动作保存单屏和双屏配置，再比较拔屏、重新登录和重启后的实际启用输出、位置、分辨率与缩放。网络 VM 覆盖临时 IPv4 模式、重连、策略更新、恢复与重启，并保留故障服务和恢复过程的诊断证据。

设备验收覆盖真实 SOPS 解密、AP 认证、外接屏幕/合盖、休眠、Secure Boot、正常注销/锁屏，以及云端权限和资料恢复。

音频、双电池、真实外屏 DPI 与触控板手感在 laptop2 验收：播放媒体、进行浏览器通话并切换麦克风/耳机；检查虚拟机客体音频；逐块外屏保存、拔插并重新登录；确认轻触点击、双指滚动和打字抑制。VM 可验证服务和配置生命周期，不能替代这些硬件行为。
