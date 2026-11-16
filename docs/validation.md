# 开发与验证

验证分为配置求值、产物构建和行为测试，使用 `flake.lock` 中的依赖和合成测试资料。检查定义集中在 [nix/checks.nix](../nix/checks.nix)。

## 开发环境

在持久化的 `~/dev/workspace/` 下使用仓库，按任务选择环境：

```sh
nix develop .#laptop  # 桌面、网络和备份开发及 VM 提交
nix develop .#vps     # 准备 VPS 材料、构建、Colmena 部署和 Worker 发布
```

交互 shell、Nix、Colmena、SSH、SOPS 和项目 Python 脚本以当前用户直接运行。Colmena 沿用 host 的 Nix 与 SSH 配置、用户状态和 SSH agent。下面的命令由 Bubblewrap 包装，仍使用原生命令名和参数；文件访问范围集中声明在 [dev-tools.nix](../nix/dev-tools.nix)。联网工具共用 host 网络，沿用 DNS、代理和 Lockdown。

| 工具 | 可访问的工作资料与持久状态 | 网络 |
| --- | --- | --- |
| actionlint、其调用的 ShellCheck | 只读项目源码 | 隔离 |
| sing-box、dnsdist、dnsproxy、go-dnscollector | 只读源码，读写 `tmp/devtools/network/` | host 网络 |
| oranc | 只读源码，读写 `tmp/devtools/cache/` 和 Nix 数据库，使用 Nix store、daemon 与缓存配置 | host 网络 |
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

该目录供网络工具共同读写。Wrangler 的登录与发布流程见 [VPS 维护](vps.md#发布证书-worker)。需要隔离的工具通过同一包装器声明正常功能所需的文件、网络和凭据权限。

## 基础检查

先检查源码和工作流：

```sh
nix build --no-link --print-build-logs .#checks.x86_64-linux.lint
```

该入口覆盖 Nix 格式、Actions、ShellCheck，以及 Python、JSON、TOML 的语法。CI 在启动缓存代理和准备开发环境之前执行同一检查。

## 配置求值

修改共享 Nix 模块、系统组合或 flake 输出后，使用与 CI 相同的[清单求值入口](../.github/ci/evaluate.py)。它通过 nix-eval-jobs 分别求值系统、开发环境、配置场景和各组 VM，再合并发布策略；worker 按内存预算回收。每个条目的结果保存在 `evaluation.jsonl`，全部成功后生成 `policy.json`，供构建与缓存发布使用。

VPS 模块或仅 `nixpkgs-remote` 的升级执行 remote 清单，laptop 改动执行 laptop 清单；共享入口执行两组。共享模块的影响范围沿实际使用者确定，涵盖导入它的系统与测试组合。交付前完成最终工作树对应范围的求值，再按改动选择产物构建和行为测试；继续修改相关配置后重新求值。

```sh
mkdir -p tmp/ci
state=$(mktemp -d "$PWD/tmp/ci/laptop.XXXXXX")
host=laptop2  # 换成要验证的主机
nix develop .#laptop --command python3 .github/ci/evaluate.py \
  --scope laptop --host "$host" --state "$state"

remote_state=$(mktemp -d "$PWD/tmp/ci/remote.XXXXXX")
nix develop .#vps --command python3 .github/ci/evaluate.py \
  --scope remote --state "$remote_state"
```

每轮验证创建新目录，并在该轮的求值、构建和报告命令中沿用它。重试保留每次执行的事件与证据；交付时核对最终工作树生成的清单。

## 检查入口

| 检查 | 负责验证 |
| --- | --- |
| `backup` | 文件选取、持久状态、调度、通知；真实 Restic 备份和恢复、独立策略、中断、锁与损坏检测 |
| `vps` | 分别使用 laptop 客户端和 VPS 服务端的真实 Trojan/Hysteria2 认证、订阅授权与换钥、出口 DNS 并发应答与缓存隔离、原生客户端配置、Wrangler HTTPS 交付与客户端识别、证书 Worker 边界 |
| `identity` | 公钥推导、已有身份自动注册、SSH 签名、Git 验签，以及换钥期间新旧身份共存 |
| `network` | 配置组合、出口选择；真实 DNS/DoT/DoH 与代理进程、FakeIP 域名恢复和记录类型、远程规则更新及离线缓存、日志和故障 |
| `desktop` | 字体匹配和混排、原生 Sway/i3 配置、显示布局选择，以及网络规则通知的确认流程 |
| `configuration-*` | 独立合成 laptop 的能力组合、服务与会话、持久化所有权和完整系统求值；`configuration-full` 同时构建凭据绑定产物 |
| `git-backup` | 临时 Git 仓库中的本地备份与远端推送 |
| `vm-network` | systemd 下的网络切换、规则下载与确认应用、失败与重启恢复，持续双栈流量、DNS、Tailscale、容器和日志隔离 |
| `vm-backup` | 实际窗口触发、独立仓库、中断和有界关机、重启恢复、gVisor 通知与补发 |
| `vm-desktop` | 三会话登录、注销、锁屏、钱包、壁纸、输入法与显示状态，以及加密启动和重启后的恢复 |
| `vm-applications` | 三会话中的真实应用启动、中文输入与退出提醒；Sway 完成共享的 DevContainer 和 Vaultwarden 全流程 |
| `vm-vps` | 实际 bootstrap 镜像的 BIOS/UEFI 启动、512 MiB 客体、DHCP/静态网络、扩容与 swap、独立于节点名的 SSH 别名、指定身份、非默认端口及 SOCKS 代理下的 Colmena 凭据下发与 test/switch、跨节点协议转发、多承载出口故障切换、路径选择与连接延续、系统 DoT 与 NTS、用户态隧道出口、重启回滚及 Wrangler 沙箱中的 Worker 打包 |
| `vm-files` | 双节点设备证书认证与撤销、HTTPS 登录和会话、WebDAV、加密 SMB、随机访问码输入与描述文件交付、跨平台证书文件导出、临时分享及请求日志 |
| `e2e` | network、backup、desktop、applications、vps 五项 VM 结果的聚合 |

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

进程场景在所需能力就绪后开始断言。DNS 夹具在统一时间预算内等待普通入口与 bootstrap 入口的 UDP、TCP 解析应答，并持续检查子进程状态；启动失败、场景异常和正常退出都回收已启动的进程。进程诊断输出到 stderr，成功结果通过 stdout 输出，便于 Nix 检查保存结果并同时显示错误现场。

## 完整验收与计时

配置求值通过后，完整项目验收继续执行所选 host 的系统构建、领域检查、OCI 缓存与更新候选集成，以及上述五项 VM 场景。文件服务按需单独运行。Home Manager 是系统构建的依赖，不单独构建。

```sh
# 使用上一步为所选 host 生成的清单。
nix develop .#laptop --command python3 .github/ci/build.py private --state "$state"
nix develop .#laptop --command python3 .github/ci/build.py dependencies --state "$state"
```

只验证 VPS 时，构建 `checks.x86_64-linux.vps` 和 `checks.x86_64-linux.vm-vps.driver`，再执行 `checks.x86_64-linux.vm-vps`。其 bootstrap 镜像和完整系统都使用 `nixpkgs-remote`；测试通过 SSH 操作真实镜像启动的来宾，覆盖部署、重启和回滚。

OCI 和更新候选集成需要创建临时 Nix store、registry 与 Git 上游，使用与 Actions 相同的原生 CI 工具：

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

文件服务模块变更时单独执行：

```sh
nix build --no-link .#checks.x86_64-linux.vm-files.driver
nix build --no-link --print-build-logs .#checks.x86_64-linux.vm-files
```

该场景使用合成凭据和证书，经过生产服务的权限、网络隔离和 gVisor 临时分享入口。

CI 的执行分组、资源安排与报告入口见[工作流说明](ci.md)。上面的原生 Nix 命令使用本机配置的资源限制，并行安排不一定与 CI 相同。

OCI 集成使用真实 Nix 构建、原生构建钩子、临时公共缓存、registry 和合成密钥，验证构建期间即可读取成功产物、大对象在检查点发布、部分构建失败时的即时反馈、日志与缓存保留，以及 registry 中断时的发布失败。它同时覆盖认证读取、NAR 下载中断后的构建与发布、诊断日志中的凭据隔离、运行时引用、公共与项目缓存去重、许可筛选、跨缓存的签名和内容恢复及事件计时。清单入口通过实际的求值错误验证逐项结果判定，并按清单核对 VM 结果。上传与构建并发访问 Nix store，执行环境需允许 oranc 正常读取可写目录中的 Nix 数据库。

更新候选集成使用临时 Git 上游和 Nix 生成的 lockfile，验证独立推进包集，以及后一组从前一组候选的新基线开始。网络 VM 另行验证宿主与 Docker 容器通过生产 oranc 服务读取缓存，以及网络和服务重启后的恢复。真实 GHCR 权限由 Actions 运行验证。

## VM 场景的分工

VM 测试驱动通过控制通道发送命令。无需输入的 SSH 探测使用 `ssh -n`，Colmena 调用关闭继承的标准输入；需要传入内容的命令使用自己的管道。远端操作设置与服务期限相符的命令超时，预期失败的场景确认具体退出状态和服务结果。诊断命令使用短超时，原始异常与诊断错误分别报告。

后台调度由[测试配置](../tests/vm/background.nix)按场景安排，配置在启动和重启时一致生效。备份与网络场景准备好数据、仓库和模拟上游后，启动对应的真实 timer 或服务；通知补发和状态刷新保留生产调度。Docker 镜像清理由场景控制，供正在使用的镜像完成工作。应用场景使用本地壁纸，桌面场景负责健康检查、壁纸定时任务及其会话生命周期。

动态创建的 timer 从调度服务入口控制。异步结果通过对应的操作 ID、消息或状态记录确认，完成记录以原子替换发布。DNS 竞速、备份中断和壁纸下载使用夹具的到达与释放信号：请求进入目标阶段后，再改变网络、停止服务或注销会话。

应用 VM 在 SDDM 登录后的真实会话中运行。三个桌面均验证 Firefox 页面与拼音输入、Kitty，以及 VS Code 编辑器和终端、Bitwarden 界面的中文输入。两个 WM 另外通过各自快捷键操作 Rofi。Sway 执行完整 DevContainer 工作区和自托管 Vaultwarden 登录、搜索；其他桌面使用本地工作区和登录界面输入框。输入经过 VM 键盘与 Fcitx，不用直接写入控件代替中文输入验证。

每个应用使用独立的 systemd unit，结束时停止启动 unit、GUI 创建的桌面 scope 和测试容器，再执行下一个应用。应用失败完成清理后继续独立场景；桌面初始化或清理失败时，汇总结果注明该桌面未执行的场景及原因，其他桌面继续运行。`application-results.json` 保存整轮结果。

应用制品中的 `*-state.json` 和 `*-result.json` 记录启动、调试连接、窗口、工作区及输入阶段，包含运行版本、会话和进程信息。VS Code 的命令行进程和 GUI 分别跟踪；窗口重开进入容器时以实际 GUI 的生命周期为准。Sway/i3 的 `*-windows.json` 保存窗口及显示后端信息。

启动失败和操作失败共用诊断入口。VS Code 的 `vscode-logs/` 保存主进程、窗口、渲染器及扩展日志；`diagnostics/` 按当次执行 ID 保存执行时间段内的用户会话 journal、coredump 元数据和可用堆栈、内核日志及进程状态，覆盖启动 unit 与 GUI scope。页面尚未建立或已经退出时，由 VM 驱动保存桌面截图。失败发生在清理之前，清理开始时间和附加错误单独记录，原始异常保留在结果及控制台日志中。

备份 VM 用一个代表仓库执行完整维护、canary 和恢复；三个仓库仍覆盖独立状态、策略及失败隔离。场景设定时间后验证自动备份的窗口与补跑。进程集成检查负责 Restic 数据和锁的行为，VM 负责 systemd、启动、关机与通知环境。

网络 VM 观察实际流量和服务状态，覆盖激活失败、重启退避和回滚。持续流量记录发送进程、连接、阶段和序号；每次状态切换分别确认发送进展与目标收到的流量。VPS 路径选择使用同一条 TCP 连接，在切换确认后发送新的请求并等待应答。FakeIP 场景通过仅携带地址的 TCP/UDP 验证同 IP 域名的不同出口，并在服务重启、地址族切换和正常系统重启后复用映射。突然断电后的场景验证 Lockdown、策略恢复，以及重新查询 A/AAAA 后的连接与出口；限制与恢复方法见[异常退出后的恢复](network.md#异常退出后的恢复)。

开发工具的隔离策略与开发环境共用。网络 VM 运行 Actionlint、DNS 解析与采集、代理连接和 oranc 发布；VPS VM 运行 Wrangler 的本地 Worker，验证这些工具在既定权限内完成正常工作。

字体匹配与中西文度量由 `desktop` 检查验证；`vm-desktop` 保存真实 Kitty 窗口的截图，供人工核对网格、连字和 emoji 显示。钱包存取在登录、重新登录和重启后验证。物理显示器上的清晰度和缩放需在设备上确认。

GUI 场景共用[驱动辅助代码](../tests/vm/gui.py)。交互期间使用桌面原生的闲置控制，测试自动锁屏时恢复生产调度。中文输入先确认窗口、控件焦点和 Fcitx 的拼音激活状态，再通过 VM 键盘输入。Qt、网页和 Electron 控件报告预编辑与提交状态；终端以实际读取到的内容确认提交。收到预期中文后，驱动才关闭输入法并继续保存或执行命令。登录和解锁等待当前 greeter 的密码焦点或锁屏程序的就绪信号。

每次输入共用一个单调时钟期限，保留阶段、耗时和应用观察到的状态。OCR 保留识别出的文本行，再合并同一基线的片段；命中和失败都保留截图与识别记录。失败采集分别执行 journal、状态和截图，各自有时间上限；采集和关机错误附在原始失败之后。

涉及调度和输入时序的改动，可以用 [CPU 竞争配置](../tests/vm/cpu-pressure.nix)运行同一场景：

```sh
nix build --no-link --print-build-logs --impure --expr '
  let
    project = builtins.getFlake ("git+file://" + toString ./.);
    test = project.checks.x86_64-linux.vm-applications;
  in import ./tests/vm/cpu-pressure.nix { inherit test; pkgs = test.config.hostPkgs; }
'
```

将 `vm-applications` 换成所需场景。测试和负载进程共用至多四个 CPU，每个 CPU 配置一半时间的竞争负载，测试的总期限相应延长。输出中的 `cpu-pressure.json` 记录实际 CPU 集合、耗时和退出状态。普通执行和竞争执行分别保留结果；再次验证时确认本轮实际启动了 VM。

原生 VM 驱动将日志和截图写入测试输出，CI 将这些证据收入[诊断制品](ci.md)。本地没有 KVM 时，可使用[远端 VM 执行说明](../tools/vm-test-mcp/README.md)中的提交方式。

## 验证边界

静态检查、进程集成和 VM 通过，不能代替物理显示器、GPU、无线硬件、真实钱包与服务商的验收。物理启动及恢复约定由具体 host 记录。

文件服务 VM 验证浏览器导航交付的描述文件、响应类型，以及其中设备身份的认证与撤销。Safari 将描述文件交给“设置”安装的提示和流程在 iOS 上确认。

失败后先根据日志判断是配置、场景还是执行环境的问题，再决定重跑范围，并保留定位问题需要的证据。
