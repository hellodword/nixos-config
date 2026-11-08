# 开发与验证

使用 `flake.lock` 中的依赖和合成测试资料。选择检查时先看改动触及的行为，不必为了一个领域的修改反复运行全部桌面。

## 检查入口

| 检查 | 负责验证 |
| --- | --- |
| `backup` | 文件选取、持久状态、调度、通知；真实 Restic 备份和恢复、独立策略、中断、锁与损坏检测 |
| `identity` | 公钥推导、已有身份自动注册、SSH 签名、Git 验签，以及换钥期间新旧身份共存 |
| `network` | 配置组合、出口选择；真实 DNS/DoT/DoH 与代理进程、路由语义、日志和故障 |
| `desktop` | 字体匹配和混排、原生 Sway/i3 配置，以及显示布局选择 |
| `configuration` | 独立合成 laptop 的能力组合、凭据绑定、服务与会话、持久化所有权和系统求值；临时 Git 仓库中的备份推送 |
| `vm-network` | systemd 下的网络切换、失败与重启恢复，持续双栈流量、DNS、Tailscale、容器和日志隔离 |
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

完整验收包含所选 host 的系统构建、五个领域检查、OCI 缓存集成以及四组 VM。Home Manager 是系统构建的依赖，不单独构建。

```sh
host=laptop2
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
nix build --no-link .#checks.x86_64-linux.backup .#checks.x86_64-linux.identity \
  .#checks.x86_64-linux.network .#checks.x86_64-linux.desktop .#checks.x86_64-linux.configuration
nix develop --command python3 -m tests.integration.cache
```

本机具备 x86_64 Linux KVM 和所需 Nix system features 时，先准备 VM 环境，再执行测试：

```sh
nix build --no-link .#checks.x86_64-linux.vm-network.driver \
  .#checks.x86_64-linux.vm-desktop.driver .#checks.x86_64-linux.vm-applications.driver \
  .#checks.x86_64-linux.vm-backup.driver
nix build --no-link --print-build-logs .#checks.x86_64-linux.e2e
```

`.driver` 包含测试脚本、客体系统和依赖，构建它不会启动 VM。构建 `vm-*` 结果才执行场景；直接构建 `e2e` 也会先准备缺失依赖。已经存在的成功 derivation 可以复用，应区分本轮执行和缓存命中。四组都实际运行成功的 VM 阶段耗时，才是完整重新执行的基线。

CI 的资源分配、阶段计时和失败记录见[工作流说明](ci.md)。OCI 集成使用真实 Nix 构建与临时 registry，验证签名发布、许可筛选、恢复内容及事件计时；不调用真实 GHCR 凭据。

## VM 场景的分工

应用 VM 在 SDDM 登录后的真实会话中运行。三个桌面均验证 Firefox 页面与拼音输入、Kitty，以及 VS Code 编辑器和终端、Bitwarden 界面的中文输入。两个 WM 另外通过各自快捷键操作 Rofi。Sway 执行完整 DevContainer 工作区和自托管 Vaultwarden 登录、搜索；其他桌面使用本地工作区和登录界面输入框。输入经过 VM 键盘与 Fcitx，不用直接写入控件代替中文输入验证。

备份 VM 用一个代表仓库执行完整维护、canary 和恢复；三个仓库仍覆盖独立状态、策略及失败隔离。进程集成检查负责 Restic 数据和锁的行为，VM 负责 systemd、启动、关机与通知环境。网络 VM 观察实际流量和服务状态，覆盖激活失败、重启退避和回滚。

桌面和应用场景共用原生驱动支持代码 `tests/vm/gui.py`。窗口等待、输入、截图和退出有截止时间，收尾错误与原始失败一起报告。测试保留按会话和应用命名的结果、日志和截图。

本机没有 KVM 时使用已准备的远端执行器，入口和兼容说明见 [VM 工具适配](../tools/vm-test-mcp/README.md)。项目测试定义仍是原生 NixOS VM tests。

## 验证边界

静态检查、进程集成和 VM 通过，不能代替物理显示器、GPU、无线硬件、真实钱包与服务商的验收。物理启动及恢复约定由具体 host 记录；桌面未决问题见[桌面指南](desktop.md#未决问题)。

失败后保留原因和必要证据，先判断是配置、场景还是执行环境的问题，再决定重跑范围。目录移动或文档调整不增加只验证名称和布局的测试。
