# 自动更新、验收与缓存发布

[ci.yml](../.github/workflows/ci.yml) 通过公共 Composite Action [infra/action/action.yml](../infra/action/action.yml) 与统一执行器 `infra#ci`（`nix-ci`）按 `laptop` 和 `remote` 两个范围执行清单求值、分组构建、VM 验收与签名缓存发布；[update.yml](../.github/workflows/update.yml) 与 [update-inputs.yml](../.github/workflows/update-inputs.yml) 定时推进依赖、验证候选提交并原子快进合并 `master`。

## 触发入口与故障排障

### 工作流入口

| 入口 | 行为 |
| --- | --- |
| `push` 到 `master` | 分别验证 `laptop` 和 `remote`，构建期间由独立旁路容器增量发布签名缓存 |
| 手动运行 `Verify and cache` | 可选 `laptop`、`remote` 或 `all`；仅 `master` 分支发布缓存 |
| 在 `master` 勾选 `initialize-cache` | 仅用当前 `GITHUB_TOKEN` 创建 GHCR 缓存索引（`nix-cache-info`），不执行构建与 VM |
| 定时或手动运行 `Update flake inputs` | 先更新并验证 `remote`（`nixpkgs-remote`、`colmena`、`cloudflare-ips-v4/v6`，锁定于根 `flake.lock`），再以最新 `master` 为基线更新 `laptop`（同步推进 `infra/flake.lock` 的公共 `nixpkgs` 与根 `flake.lock` 的桌面输入） |

仅当候选包含受管锁文件白名单（`update.allowedLockfiles`）内的实质输入变更（且不全为 `ignoreOnlyInputs` 声明的纯规则快照变化）时才进入验证。验证与缓存发布通过后，`nix-ci update merge` 在推送候选分支与创建 PR 前核对远端 `refs/heads/master` 是否仍等于候选基线 `base`：若 `master` 在验证期间已前进则记录原因并以退出码 `0` 正常结束；否则创建附带验证运行链接的 PR，调用非强制 `force=false` 原子快进合并并清理临时分支。

### 故障定位与诊断制品

验证失败时先查看 Actions 页面 Summary，再下载保留 7 天的 `diagnostics-<scope>[-<host>]-<attempt>` 制品：

| 记录路径 | 排查用途 |
| --- | --- |
| Summary、`manifest.json`、`timings.jsonl` | 清单任务组定义、各阶段墙钟耗时、来源归类（`executed` / `cache restored` / `local reuse` / `skipped` / `failed`）与检查点等待时间 |
| `logs/<pass>/<group>/<attempt>.log` | 普通检查与 VM 的完整构建及串口控制台输出 |
| `evaluation.jsonl` | `nix-eval-jobs` 逐项求值的 derivation、输出路径、耗时与报错详情 |
| `publication-paths.jsonl`、`published-paths.json`、`publisher.log`、`cache/status.json` | 远端 `.narinfo` 命中/排除统计、已上传对象清单、NAR 体积及旁路发布容器状态 |
| `resources.jsonl`、`oom-*.log`、`oranc.log`、`monitor.log` | CPU/内存/swap/磁盘采样、容器 cgroup 内存峰值与 `oom_kill` 计数及本地缓存代理请求日志 |
| `vm/<pass>/<check>/<attempt>/` | VM 测试导出的截图、OCR 记录、分阶段流量统计、应用工作流状态与失败现场 |

构建阶段首次出现失败 derivation 时立即在 Actions 页面发出 `::error::` 标注，其余独立构建继续运行以保留可复用的成功产物。`nix-ci report verify` 按 derivation 路径精确核对全部 `required = true` 目标在最新一次尝试中均成功完成。

## 容器隔离与执行顺序

每次运行按 `${RUNNER_TEMP}/nix-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` 分配独立状态目录、独立 Docker 卷与容器名，并在 Ubuntu Runner 上清理冗余 SDK 目录、挂载 `8 GiB` swap 与 `/dev/kvm`：
- **构建容器 `nix-ci-<run>-<attempt>`**：以只读方式挂载产品工作树 `/workspace:ro` 与公共基础设施 `/infra:ro`，统一注入 `--ulimit nofile=65536:1048576`，不注入任何缓存签名私钥或写凭据；
- **发布旁路容器 `nix-ci-publisher-<run>-<attempt>`**：仅在增量发布模式下启动，独立持有 `ORANC_SIGNING_KEY`、`ORANC_USERNAME` 与 `ORANC_PASSWORD`，共享同一 `/nix` 卷并通过 `/ci/cache` 目录消费构建队列。

| 阶段 | 内容 |
| --- | --- |
| 准备与启动缓存 | 磁盘清理、swap/KVM/Nix 卷初始化，按 `infra#oranc.outPath` 恢复或构建 `oranc` 闭包（`master` 未命中且归档不超过 `512 MiB` 时写回 Actions Cache） |
| 缓存代理与清单求值 | 在 `127.0.0.2:37515` 启动本地 `oranc` 读取代理并通过匿名 `GET /nix-cache-info` 校验可读性，运行 `nix-ci evaluate` 写出 `manifest.json`，执行 `lint`、`cache` 与 `updates` 集成检查 |
| `laptop` 执行组 | 依次构建 `private`、`dependencies`（含全部非 VM 检查与 5 个 VM `.driver`），完成依赖检查点后顺序执行 `vm-network-backup`、`vm-desktop`、`vm-applications` |
| `remote` 执行组 | 先构建无 KVM 需求的 `dependencies`，再在 `kvm = true` 组构建 `vm-vps-driver`（含 `vpsBootstrap` BIOS/UEFI 磁盘镜像）并执行 `vm-vps` |
| 汇总与发布收尾 | `nix-ci report verify` 核对必需目标，完成最终检查点上传、采样资源并输出 Markdown Summary |

## 首次启用步骤

1. 在公开仓库 **Settings → Actions → General** 允许 GitHub 官方 Actions，并勾选允许工作流创建与批准 PR。
2. 若 GHCR 缓存 package 尚未建立，在 **Actions → Verify and cache** 选择 `master` 并勾选 `initialize-cache` 运行一次。
3. 打开 GitHub **Packages → 缓存 package → Package settings**：将可见性设为 **Public**；取消 **Inherit access from repository**，在 **Manage Actions access** 中为本仓库显式设置 **Write** 角色（参见 [GitHub Package 权限说明](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)）。
4. 按 [构建缓存签名密钥](cache.md#签名密钥管理) 生成密钥对，将公钥写入 `nix/cache-identity.json`，私钥写入仓库 Actions Secret `NIX_CACHE_SIGNING_KEY`。
5. 在 `master` 手动运行一次不勾选 `initialize-cache` 的 **Verify and cache**，确认构建、VM 验收与旁路缓存发布全部通过。
