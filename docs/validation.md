# 开发与验证

验证分为配置求值、产物构建和行为测试，使用 `flake.lock` 中的依赖和合成测试资料。检查定义集中在 [nix/checks.nix](../nix/checks.nix)。

## 开发环境

在持久化的 `~/dev/workspace/` 下使用仓库，按任务选择环境：

```sh
nix develop .#laptop  # 桌面、网络和备份开发及 VM 提交
nix develop .#vps     # 准备 VPS 材料、构建、Colmena 部署和 Worker 发布
```

交互 shell、SOPS 和项目 Python 脚本以当前用户运行。下面的命令由 Bubblewrap 包装，仍使用原生命令名和参数；文件访问范围集中声明在 [dev-shells.nix](../nix/dev-shells.nix)。联网工具共用 host 网络，沿用 DNS、代理和 Lockdown。

| 工具 | 可访问的工作资料与持久状态 | 网络 |
| --- | --- | --- |
| actionlint、其调用的 ShellCheck | 只读项目源码 | 隔离 |
| sing-box、dnsdist、dnsproxy、go-dnscollector | 只读源码，读写 `tmp/devtools/network/` | host 网络 |
| oranc | 只读源码，读写 `tmp/devtools/cache/` 和 Nix 数据库，使用 Nix store、daemon 与缓存配置 | host 网络 |
| Colmena | 只读源码、`tmp/vps/metadata.json` 和 `tmp/vps/nodes/`，使用 Nix；读写 `~/.ssh/`，读取系统 SSH 配置、公钥并使用 SSH agent | host 网络 |
| Wrangler | 只读当前 Worker 目录，读写项目根 `.wrangler/` 登录状态 | host 网络 |

每个沙箱工具都有 `tmp/.cache/nixos-config-tools/<工具>/`，其中 `cache/` 和 `logs/` 保存缓存与日志，`tmp/` 保存每次运行的临时文件。正常退出即清理本次临时目录；再次调用时，systemd-tmpfiles 清理一天前遗留的临时文件及三十天未使用的缓存、日志。运行中的目录通过文件锁保留。Wrangler 登录状态和部署材料单独保存，由用户清理。

开发 shell 将辅助工具的 `XDG_CACHE_HOME` 和 `TMPDIR` 放在同一根目录的 `shell/` 下，Go 与 npm 使用各自子目录。VM 提交客户端的导出缓存也随之保存在磁盘工作区，容量由客户端自身管理。

项目位于持久工作区时，这些目录跨注销、重启保留，磁盘空间由所在文件系统提供。Nix 继续使用已有的持久缓存，daemon 构建使用系统配置的临时目录。工具启动会检查缓存文件系统，避免在 tmpfs 工作区产生大量文件。沙箱保留 host 的 Unix 文件权限；例如 oranc 发布仍需要当前用户具备 Nix 数据库目录的访问权限。

测试代理时，将所需配置放入专用目录，再运行原生命令：

```sh
install -d -m 700 tmp/devtools/network
# 将本轮需要的 sing-box 配置保存为 tmp/devtools/network/config.json。
cd tmp/devtools/network
sing-box check -c config.json
sing-box run -c config.json
```

该目录供网络工具共同读写；`tmp/vps/` 保存另一类部署材料，只向 Colmena 开放所需部分。Wrangler 的登录与发布流程见 [VPS 维护](vps.md#发布-worker-与管理证书)。新增工具时复用同一包装器，按其正常功能声明文件、网络和凭据权限。

## 配置求值

修改共享 Nix 模块、系统组合或 flake 输出后，先在仓库根目录执行：

```sh
nix flake check --no-build --no-update-lock-file
```

求值检查已声明的系统、软件包、开发环境和检查定义，包括各组 VM 的配置。通过后，按改动影响选择产物构建和行为测试。共享模块的影响范围沿实际使用者确定，涵盖导入它的系统与测试组合。

VPS 模块或仅 `nixpkgs-remote` 的升级，使用下面的 remote 清单求值，检查其系统、工具和测试；laptop 改动使用 laptop 清单。共享入口的变动执行完整 flake 求值和两组清单求值。交付前必须完成最终工作树对应范围的求值。求值后若继续修改相关配置，重新执行这一步；验证记录分别说明配置求值、产物构建和行为场景的结果。

CI 使用同一[清单求值入口](../nix/ci.nix)，修改构建或发布清单时按影响范围执行：

```sh
host=laptop2  # 换成要验证的主机
SCOPE=laptop HOST="$host" nix eval --no-update-lock-file --json --impure \
  --expr 'import ./nix/ci.nix { flake = builtins.getFlake ("git+file://" + toString ./.); hostName = builtins.getEnv "HOST"; scope = builtins.getEnv "SCOPE"; }' \
  > /dev/null

nix eval --no-update-lock-file --json --impure \
  --expr 'import ./nix/ci.nix { flake = builtins.getFlake ("git+file://" + toString ./.); scope = "remote"; }' \
  > /dev/null
```

## 检查入口

| 检查 | 负责验证 |
| --- | --- |
| `backup` | 文件选取、持久状态、调度、通知；真实 Restic 备份和恢复、独立策略、中断、锁与损坏检测 |
| `vps` | 分别使用 laptop 客户端和 VPS 服务端的真实 Trojan/Hysteria2 认证、订阅授权与换钥、出口 DNS 并发应答与缓存隔离、原生客户端配置、Wrangler HTTPS 交付与客户端识别、证书 Worker 边界 |
| `identity` | 公钥推导、已有身份自动注册、SSH 签名、Git 验签，以及换钥期间新旧身份共存 |
| `network` | 配置组合、出口选择；真实 DNS/DoT/DoH 与代理进程、FakeIP 域名恢复和记录类型、远程规则更新及离线缓存、日志和故障 |
| `desktop` | 字体匹配和混排、原生 Sway/i3 配置、显示布局选择，以及网络规则通知的确认流程 |
| `configuration` | 独立合成 laptop 的能力组合、凭据绑定、服务与会话、持久化所有权和系统求值；临时 Git 仓库中的备份推送 |
| `vm-network` | systemd 下的网络切换、规则下载与确认应用、失败与重启恢复，持续双栈流量、DNS、Tailscale、容器和日志隔离 |
| `vm-backup` | 实际窗口触发、独立仓库、中断和有界关机、重启恢复、gVisor 通知与补发 |
| `vm-desktop` | 三会话登录、注销、锁屏、钱包、壁纸、输入法与显示状态，以及加密启动和重启后的恢复 |
| `vm-applications` | 三会话中的真实应用启动、中文输入与退出提醒；Sway 完成共享的 DevContainer 和 Vaultwarden 全流程 |
| `vm-vps` | 实际 bootstrap 镜像的 BIOS/UEFI 启动、512 MiB 客体、DHCP/静态网络、扩容与 swap、真实 SSH、Colmena 凭据下发与 test/switch、跨节点协议转发、多承载出口故障切换、路径选择与连接延续、系统 DoT 与 NTS、用户态隧道出口、重启回滚及 Wrangler 沙箱中的 Worker 打包 |
| `e2e` | 上述 `vm-*` 结果的聚合 |

例如，身份脚本的修改先运行：

```sh
nix build --no-link .#checks.x86_64-linux.identity
```

需要更快反馈时，可在开发环境运行对应的 Python 场景：

```sh
nix develop .#laptop --command python3 -m unittest tests.unit.test_backup -v
nix develop .#laptop --command python3 -m tests.integration.backup -v
```

这些入口执行同一份测试，不要求本地命令和 Nix 检查都重复运行。SSH 自动注册与会话生命周期之间的集成由桌面 VM 负责；字体匹配和实际 Kitty 渲染各有独立边界。

## 完整验收与计时

配置求值通过后，完整项目验收继续执行所选 host 的系统构建、领域检查、OCI 缓存与更新候选集成，以及所有 VM 场景。Home Manager 是系统构建的依赖，不单独构建。

```sh
host=laptop2  # 换成要验证的主机
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
nix build --no-link .#checks.x86_64-linux.backup .#checks.x86_64-linux.identity \
  .#checks.x86_64-linux.network .#checks.x86_64-linux.desktop .#checks.x86_64-linux.configuration .#checks.x86_64-linux.vps
nix develop .#laptop --command python3 -m tests.integration.cache
nix develop .#laptop --command python3 -m tests.integration.updates
```

只验证 VPS 时，构建 `checks.x86_64-linux.vps` 和 `checks.x86_64-linux.vm-vps.driver`，再执行 `checks.x86_64-linux.vm-vps`。其 bootstrap 镜像和完整系统都使用 `nixpkgs-remote`；测试通过 SSH 操作真实镜像启动的来宾，覆盖部署、重启和回滚。

CI 工具可独立构建，用于复现 OCI 和更新候选集成：

```sh
ci_tools=$(nix build --no-link --print-out-paths --impure --expr \
  'import ./nix/ci-tools.nix { flake = builtins.getFlake ("git+file://" + toString ./.); scope = "remote"; }')
PATH="$ci_tools/bin:$PATH" python3 -m tests.integration.cache --nixpkgs-input nixpkgs-remote
PATH="$ci_tools/bin:$PATH" python3 -m tests.integration.updates
```

本机具备 x86_64 Linux KVM 和所需 Nix system features 时，先准备 VM 环境，再执行测试：

```sh
nix build --no-link .#checks.x86_64-linux.vm-network.driver \
  .#checks.x86_64-linux.vm-desktop.driver .#checks.x86_64-linux.vm-applications.driver \
  .#checks.x86_64-linux.vm-backup.driver .#checks.x86_64-linux.vm-vps.driver
nix build --no-link --print-build-logs .#checks.x86_64-linux.e2e
```

`.driver` 包含测试脚本、客体系统和依赖，构建它不会执行测试场景；部分启动磁盘镜像的制作仍需要 KVM。构建 `vm-*` 结果才执行场景；直接构建 `e2e` 也会先准备缺失依赖。已经存在的成功 derivation 可以复用，应区分本轮执行和缓存命中。所有场景都实际运行成功的 VM 阶段耗时，才是完整重新执行的基线。

CI 的执行分组、资源安排与报告入口见[工作流说明](ci.md)。上面的原生 Nix 命令使用本机配置的资源限制，并行安排不一定与 CI 相同。

OCI 集成使用真实 Nix 构建、原生构建钩子、临时公共缓存、registry 和合成密钥，验证构建期间即可读取成功产物、大对象在检查点发布、部分构建失败后的缓存保留，以及 registry 中断时的发布失败。它同时覆盖运行时引用、公共与项目缓存去重、许可筛选、跨缓存的签名和内容恢复及事件计时。上传与构建并发访问 Nix store，执行环境需允许 oranc 正常读取可写目录中的 Nix 数据库。更新候选集成使用临时 Git 上游和 Nix 生成的 lockfile，验证独立推进包集，以及后一组从前一组候选的新基线开始。网络 VM 另行验证宿主与 Docker 容器通过生产 oranc 服务读取缓存，以及网络和服务重启后的恢复。真实 GHCR 权限由 Actions 运行验证。

## VM 场景的分工

后台调度由[测试配置](../tests/vm/background.nix)按场景安排，配置在启动和重启时一致生效。备份与网络场景准备好数据、仓库和模拟上游后，启动对应的真实 timer 或服务；通知补发和状态刷新保留生产调度。应用场景使用本地壁纸，桌面场景负责健康检查、壁纸定时任务及其会话生命周期。

动态创建的 timer 从调度服务入口控制。异步结果通过对应的操作 ID、消息或状态记录确认，等待期限覆盖实际执行与重试周期。桌面场景通过明确的启动屏障安排健康检查与原生注销重叠，并在壁纸服务器延迟响应时注销 Sway，验证任务收尾、返回 SDDM 和重新登录后的恢复。

应用 VM 在 SDDM 登录后的真实会话中运行。三个桌面均验证 Firefox 页面与拼音输入、Kitty，以及 VS Code 编辑器和终端、Bitwarden 界面的中文输入。两个 WM 另外通过各自快捷键操作 Rofi。Sway 执行完整 DevContainer 工作区和自托管 Vaultwarden 登录、搜索；其他桌面使用本地工作区和登录界面输入框。输入经过 VM 键盘与 Fcitx，不用直接写入控件代替中文输入验证。

备份 VM 用一个代表仓库执行完整维护、canary 和恢复；三个仓库仍覆盖独立状态、策略及失败隔离。场景设定时间后验证自动备份的窗口与补跑。进程集成检查负责 Restic 数据和锁的行为，VM 负责 systemd、启动、关机与通知环境。

重启后先通过真实投递确认通知服务可用，再恢复备份和检查。最终在覆盖生产补发周期的同一等待期限内，确认最新备份通知已送达、三个仓库的待发送队列已清空；失败时保存待发送与已投递记录、timer 状态和通知服务日志。

网络 VM 观察实际流量和服务状态，覆盖激活失败、重启退避和回滚。FakeIP 场景通过仅携带地址的 TCP/UDP 验证同 IP 域名的不同出口，并在服务重启、地址族切换和正常系统重启后复用映射。突然断电后的场景验证 Lockdown、策略恢复，以及重新查询 A/AAAA 后的连接与出口；旧映射保留不作为该场景的通过条件，限制与恢复方法见[异常退出后的恢复](network.md#异常退出后的恢复)。

KDE Connect 两端依次完成 D-Bus 与 LAN 后端初始化，通过双方可达状态进入配对和文件传输；发现期间由单端有界刷新。初始化、发现或配对失败时输出两端的设备树、设备列表和守护进程日志。

字体匹配与中西文度量由 `desktop` 检查验证；`vm-desktop` 保存真实 Kitty 窗口的截图，供人工核对网格、连字和 emoji 显示。钱包存取在登录、重新登录和重启后验证。物理显示器上的清晰度和缩放需在设备上确认。

GUI 场景共用[原生驱动辅助代码](../tests/vm/gui.py)。窗口焦点、应用控件和写出的结果用于确认操作生效；OCR 用于确认可见界面。Rofi 输入前核对同一面板中的标题、计数与可见选项，连续两帧一致后输入，提交前检查完整输入和唯一候选。中文输入仍经过真实键盘与输入法。

OCR 只观察画面。活动线程在交互场景中保持会话唤醒，完整输入序列独占键盘；悬浮提示、空闲锁屏和会话退出期间暂停活动输入。解锁前先等待锁屏画面，再唤醒密码控件。命中和失败均保存原图、识别区域、文字坐标及耗时；诊断区分等待界面的总期限、识别进程超时和命令错误。启动阶段失败时保留画面和串口日志，通过 QEMU 释放来宾；已连接的来宾另行收集系统日志。

网络持续流量在停止发送后取得带锁快照，通过文件复制交给断言。原始 `observations-final.jsonl` 随结果保留，解析错误包含行号和附近内容。通知场景使用[固定测试证书](../tests/fixtures/notification-tls)连接模拟上游，按各次调用的正文逐条核对送达状态、标题、分组和声音；失败时保存 Bark 响应、HAProxy 与模拟器日志。

原生 driver 将这些证据写入测试输出目录；Actions 中的下载位置见 [CI 故障记录](ci.md#资源和故障记录)。

本机没有 KVM 时使用已准备的远端执行器，入口见[远端 VM 执行](../tools/vm-test-mcp/README.md)。项目测试定义仍是原生 NixOS VM tests。

## 验证边界

静态检查、进程集成和 VM 通过，不能代替物理显示器、GPU、无线硬件、真实钱包与服务商的验收。物理启动及恢复约定由具体 host 记录。

KDE Connect 连接销毁和设备 D-Bus 对象消失的底层原因仍待定位。场景通过表示本轮完成了发现、配对和文件传输。

失败后先根据日志判断是配置、场景还是执行环境的问题，再决定重跑范围，并保留定位问题需要的证据。
