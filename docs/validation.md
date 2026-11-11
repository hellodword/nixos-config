# 开发与验证

验证分为配置求值、产物构建和行为测试，使用 `flake.lock` 中的依赖和合成测试资料。检查定义集中在 [nix/checks.nix](../nix/checks.nix)。

## 配置求值

修改 Nix 模块、系统组合、flake 输出或锁定输入后，先在仓库根目录执行：

```sh
nix flake check --no-build --no-update-lock-file
```

求值检查已声明的系统、软件包、开发环境和检查定义，包括各组 VM 的配置。通过后，按改动影响选择产物构建和行为测试。共享模块的影响范围沿实际使用者确定，涵盖导入它的系统与测试组合。

上述改动交付前必须完成最终工作树的求值。求值后若继续修改相关配置，重新执行这一步；验证记录分别说明配置求值、产物构建和行为场景的结果。

修改 CI 构建或发布清单的生成逻辑时，还需执行工作流使用的[清单求值入口](../nix/ci.nix)：

```sh
host=laptop2  # 换成要验证的主机
HOST="$host" nix eval --no-update-lock-file --json --impure \
  --expr 'import ./nix/ci.nix { flake = builtins.getFlake ("git+file://" + toString ./.); hostName = builtins.getEnv "HOST"; }' \
  > /dev/null
```

## 检查入口

| 检查 | 负责验证 |
| --- | --- |
| `backup` | 文件选取、持久状态、调度、通知；真实 Restic 备份和恢复、独立策略、中断、锁与损坏检测 |
| `identity` | 公钥推导、已有身份自动注册、SSH 签名、Git 验签，以及换钥期间新旧身份共存 |
| `network` | 配置组合、出口选择；真实 DNS/DoT/DoH 与代理进程、FakeIP 域名恢复和记录类型、远程规则更新及离线缓存、日志和故障 |
| `desktop` | 字体匹配和混排、原生 Sway/i3 配置、显示布局选择，以及网络规则通知的确认流程 |
| `configuration` | 独立合成 laptop 的能力组合、凭据绑定、服务与会话、持久化所有权和系统求值；临时 Git 仓库中的备份推送 |
| `vm-network` | systemd 下的网络切换、规则下载与确认应用、失败与重启恢复，持续双栈流量、DNS、Tailscale、容器和日志隔离 |
| `vm-backup` | 实际窗口触发、独立仓库、中断和有界关机、重启恢复、gVisor 通知与补发 |
| `vm-desktop` | 三会话登录、注销、锁屏、钱包、壁纸、输入法与显示状态，以及加密启动和重启后的恢复 |
| `vm-applications` | 三会话中的真实应用启动、中文输入与退出提醒；Sway 完成共享的 DevContainer 和 Vaultwarden 全流程 |
| `e2e` | 上述四个 `vm-*` 结果的聚合 |

例如，身份脚本的修改先运行：

```sh
nix build --no-link .#checks.x86_64-linux.identity
```

需要更快反馈时，可在开发环境运行对应的 Python 场景：

```sh
nix develop --command python3 -m unittest tests.unit.test_backup -v
nix develop --command python3 -m tests.integration.backup -v
```

这些入口执行同一份测试，不要求本地命令和 Nix 检查都重复运行。SSH 自动注册与会话生命周期之间的集成由桌面 VM 负责；字体匹配和实际 Kitty 渲染各有独立边界。

## 完整验收与计时

配置求值通过后，完整验收继续执行所选 host 的系统构建、五个领域检查、OCI 缓存与更新候选集成，以及四组 VM。Home Manager 是系统构建的依赖，不单独构建。

```sh
host=laptop2  # 换成要验证的主机
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
nix build --no-link .#checks.x86_64-linux.backup .#checks.x86_64-linux.identity \
  .#checks.x86_64-linux.network .#checks.x86_64-linux.desktop .#checks.x86_64-linux.configuration
nix develop --command python3 -m tests.integration.cache
nix develop --command python3 -m tests.integration.updates
```

本机具备 x86_64 Linux KVM 和所需 Nix system features 时，先准备 VM 环境，再执行测试：

```sh
nix build --no-link .#checks.x86_64-linux.vm-network.driver \
  .#checks.x86_64-linux.vm-desktop.driver .#checks.x86_64-linux.vm-applications.driver \
  .#checks.x86_64-linux.vm-backup.driver
nix build --no-link --print-build-logs .#checks.x86_64-linux.e2e
```

`.driver` 包含测试脚本、客体系统和依赖，构建它不会执行测试场景；部分启动磁盘镜像的制作仍需要 KVM。构建 `vm-*` 结果才执行场景；直接构建 `e2e` 也会先准备缺失依赖。已经存在的成功 derivation 可以复用，应区分本轮执行和缓存命中。四组都实际运行成功的 VM 阶段耗时，才是完整重新执行的基线。

CI 的执行分组、资源安排与报告入口见[工作流说明](ci.md)。上面的原生 Nix 命令使用本机配置的资源限制，并行安排不一定与 CI 相同。

OCI 集成使用真实 Nix 构建、原生构建钩子、临时公共缓存、registry 和合成密钥，验证构建期间即可读取成功产物、大对象在检查点发布、部分构建失败后的缓存保留，以及 registry 中断时的发布失败。它同时覆盖运行时引用、公共与项目缓存去重、许可筛选、跨缓存的签名和内容恢复及事件计时。上传与构建并发访问 Nix store，执行环境需允许 oranc 正常读取可写目录中的 Nix 数据库。网络 VM 另行验证宿主与 Docker 容器通过生产 oranc 服务读取缓存，以及网络和服务重启后的恢复。真实 GHCR 权限由 Actions 运行验证。

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
