# 自动更新、验收与缓存发布

[ci.yml](../.github/workflows/ci.yml) 按 `laptop` 和 `remote` 两个范围执行构建、VM 验收与增量缓存发布；[update.yml](../.github/workflows/update.yml) 与 [update-inputs.yml](../.github/workflows/update-inputs.yml) 定时推进依赖、验证候选提交并快进合并 `master`。

## 触发入口与故障排障

### 工作流入口

| 入口 | 行为 |
| --- | --- |
| `push` 到 `master` | 分别验证 `laptop` 和 `remote`，构建期间由独立旁路容器增量发布签名缓存 |
| 手动运行 `Verify and cache` | 可选 `laptop`、`remote` 或 `all`；仅 `master` 分支发布缓存 |
| 在 `master` 勾选 `initialize-cache` | 仅用当前 `GITHUB_TOKEN` 创建 GHCR 缓存索引（`nix-cache-info`），不执行构建与 VM |
| 定时或手动运行 `Update flake inputs` | 先更新并验证 `remote`（`nixpkgs-remote`、`colmena`、`cloudflare-ips-v4/v6`），再以最新 `master` 为基线更新 `laptop`（10 个输入） |

仅当候选包含实际输入变更（且不全为纯规则种子快照变化）时才进入验证。验证与缓存发布通过后，`update.py` 在推送候选分支与创建 PR 前再次核对远端 `refs/heads/master` 是否仍等于候选基线 `base`：若 `master` 在验证期间已前进则直接放弃本次合并，留待下一轮从新基线生成候选；否则通过 PR 快进合并并清理候选分支。

### 故障定位与诊断制品

验证失败时先查看 Actions 页面 Summary，再下载保留 7 天的 `diagnostics-<scope>[-<host>]-<attempt>` 制品：

| 记录路径 | 排查用途 |
| --- | --- |
| Summary、`timings.jsonl` | 各阶段墙钟耗时、缓存恢复与实际构建活动对比、发布检查点等待时间 |
| `logs/<pass>/<group>/<attempt>.log` | 普通检查与 VM 的完整构建及串口控制台输出 |
| `evaluation.jsonl` | `nix-eval-jobs` 逐项求值的 derivation、输出路径、耗时与报错详情 |
| `publication-paths.jsonl`、`publisher.log`、`cache/status.json` | 每次发布的命中/排除统计、NAR 体积及旁路发布容器状态 |
| `resources.jsonl`、`oom-*.log`、`oranc.log`、`monitor.log` | CPU/内存/swap/磁盘采样、OOM 记录及本地缓存代理请求日志 |
| `vm/<pass>/<check>/<attempt>/` | VM 测试导出的截图、OCR 记录、分阶段流量统计、应用工作流状态与失败现场 |

VM 阶段判定仅采用当前清单 derivation 最新一次已启动的执行记录；构建阶段首次出现失败 derivation 时立即在 Actions 页面发出标注，其余独立构建继续运行以保留可复用的成功缓存。

## 容器隔离与执行顺序

每个矩阵任务在 Ubuntu Runner 上准备 swap、KVM 与独立 Docker 卷 `nixos-ci-store`：
- **构建容器 `nixos-ci`**：以 `--volume "$GITHUB_WORKSPACE:/workspace:ro"` 只读挂载仓库源码，设置有界 `nofile` 上限（避免 `gawk` 按无限描述符上限分配巨量内存），不注入任何缓存发布凭据；
- **发布旁路容器 `nixos-ci-publisher`**：仅在发布模式下启动，独立持有 `ORANC_SIGNING_KEY`、`ORANC_USERNAME` 与 `ORANC_PASSWORD`，挂载同一 `nixos-ci-store:/nix` 卷并通过共享 `/ci/cache` 目录消费构建队列。

| 阶段 | 内容 |
| --- | --- |
| 准备与静态门禁 | 磁盘清理、swap/KVM/Nix 卷初始化、运行 `checks.x86_64-linux.lint` |
| 缓存代理与进程集成 | 准备并缓存 `oranc` 启动闭包，校验匿名读取（发布模式同时校验签名密钥匹配），运行 `cache` 与 `updates` 进程集成测试 |
| 清单求值与依赖构建 | `evaluate.py` 求值目标范围全部任务与排除策略（写出 `policy.json`），单并发满核构建系统、领域检查与 VM `.driver`，旁路容器后台增量上传可再分发产物 |
| `laptop` VM 套件 | 依次执行 `vm-network`、`vm-backup`、`vm-files`，再执行 `vm-desktop`、`vm-applications` |
| `remote` VM 套件 | 从 `vpsBootstrap` BIOS/UEFI 原始镜像启动客体，执行 `vm-vps` 全链路部署与协议验证 |
| 汇总与发布收尾 | 核对全部 VM 结果，等待旁路容器完成大对象与剩余队列上传并安全退出 |

## 首次启用步骤

1. 在公开仓库 **Settings → Actions → General** 允许 GitHub 官方 Actions，并勾选允许工作流创建与批准 PR。
2. 若 GHCR 缓存 package 尚未建立，在 **Actions → Verify and cache** 选择 `master` 并勾选 `initialize-cache` 运行一次。
3. 打开 GitHub **Packages → 缓存 package → Package settings**：将可见性设为 **Public**；取消 **Inherit access from repository**，在 **Manage Actions access** 中为本仓库显式设置 **Write** 角色（参见 [GitHub Package 权限说明](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)）。
4. 按 [构建缓存签名密钥](cache.md#签名密钥管理) 生成密钥对，将公钥写入 `nix/cache-identity.json`，私钥写入仓库 Actions Secret `NIX_CACHE_SIGNING_KEY`。
5. 在 `master` 手动运行一次不勾选 `initialize-cache` 的 **Verify and cache**，确认构建、VM 验收与旁路缓存发布全部通过。
