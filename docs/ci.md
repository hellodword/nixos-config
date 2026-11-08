# 自动更新、验收与缓存发布

[验证工作流](../.github/workflows/ci.yml)负责构建、测试和缓存发布；[更新工作流](../.github/workflows/update.yml)负责选择新的上游版本，并在验证成功后发布候选提交。

## 入口和候选提交

| 入口 | 行为 |
| --- | --- |
| push 到 `master` | 验证该提交，在构建后和验证收尾时发布可用的签名缓存 |
| 手动运行 Verify and cache | 默认验证所选 ref；只有 master 发布缓存 |
| 在 master 手动勾选 `initialize-cache` | 只创建缓存索引，供首次设置 package；不执行系统构建和 VM |
| 定时运行，或在 master 手动运行 Update flake inputs | 更新指定输入；无变化则结束，有变化则准备候选提交并调用验证工作流 |

更新时间与输入列表见[更新工作流](../.github/workflows/update.yml)。本地更新及按需升级见[主机维护](maintenance.md#更新与验证)。

更新任务先创建候选提交并交给验证任务。构建针对最终提交，系统的 `configurationRevision` 与验收 SHA 一致；失败候选不推送。

所有 host 成功后，工作流创建 PR，将 master 快进到已验证的提交，再删除候选分支。若 master 已前进而无法快进，本轮关闭 PR 并删除分支，下一次从新基线开始。仓库分支策略必须允许这种合并方式；调整保护规则时需核对[合并实现](../.github/ci/update.py)。

## 主机与执行顺序

验证工作流的 `matrix.host` 选择需要验收的主机，当前支持 `x86_64-linux`。主机依次执行，某台失败仍继续检查其余主机；自动更新等待全部成功才能合并。新增机器见[增加主机](maintenance.md#增加主机)。

| 步骤 | 内容 |
| --- | --- |
| 准备 | 清理指定 runner SDK、建立 swap、KVM、独立 Nix store 和资源采样 |
| 缓存与工具 | 确认项目缓存可匿名读取，准备开发工具；发布任务核对签名身份和写入权限 |
| 静态检查与集成 | 工作流、Shell、Nix 格式检查及 OCI 缓存集成 |
| 求值与构建 | 求值进程退出后，构建受限依赖、所选系统、领域检查和全部 VM driver |
| 第一次发布 | 发布已经完成且可再分发的路径；构建失败也保留成功产物 |
| VM 第一组 | network 与 backup 并行 |
| VM 第二组 | desktop 单独运行 |
| VM 第三组 | applications 单独运行 |
| 汇总与第二次发布 | 四组 VM 全部通过才生成聚合结果；发布本轮新增的可再分发路径 |

同一个 host 的步骤共享 runner、容器和 Nix store。不同 host 使用独立 runner，通过 GHCR 复用相同依赖和测试结果。各项检查的范围见[验证指南](validation.md)。

新的提交不会中断正在运行的验证；等待中的验证只保留最新一项，因此连续 push 的每个中间提交不一定都会执行。更新与验证使用独立的并发组，避免调用方占用验证需要的组。排队规则见 [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)。

缓存发布和测试分别报告状态，任意一项失败都会使验证任务失败。依赖准备成功后，某组 VM 失败仍继续执行其余组。缓存可在全部验证完成前发布，其存在不代表验收通过或已经部署。自动更新直接调用验证工作流，因为 [GITHUB_TOKEN 引发的 push](https://docs.github.com/en/actions/concepts/security/github_token)不会再次触发 push 工作流。

## 首次启用

1. 使用公开仓库，在 Settings → Actions → General 中允许使用 GitHub 创建的 actions。
2. 在同一页面允许工作流创建 PR。验证任务需要读取仓库和写入 packages；更新合并任务需要写入 contents 和 pull requests。
3. 如果缓存 package 尚不存在，在 Actions → Verify and cache → Run workflow 中选择 master、勾选 `initialize-cache`。该入口使用本轮 GITHUB_TOKEN 发布 `nix-cache-info`，无需签名私钥；已有 package 可跳过此步。
4. 从 GitHub 头像进入 Your profile → Packages → 缓存 package → Package settings。在 Danger Zone → Change visibility 中设为 **Public**；这项公开操作不能撤回。若 package 关联了仓库，取消 **Inherit access from repository**，再在 **Manage Actions access** 中添加或确认本仓库，角色选 **Write**。首次通过 Actions 发布会自动授予该仓库 package Admin，因此仍需手动确认角色，不能只看 workflow 中的 `packages: write`。[GitHub package 权限说明](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)区分了 package 角色、仓库关联和可见性。
5. 在仓库 Settings → Secrets and variables → Actions 设置 `NIX_CACHE_SIGNING_KEY`，复用与仓库公钥配套的私钥。生成、核对及可选 CLI 上传命令见[缓存签名密钥](cache.md#签名密钥)。
6. 在 master 手动运行 Verify and cache，保持 `initialize-cache` **不勾选**。确认验证和发布成功；再观察一次更新任务，核对 PR 合并的 SHA 与验证的候选提交一致。

初始化使用 GITHUB_TOKEN，package 的公开设置和访问角色由上述网页步骤管理。日常验证在系统构建前检查匿名读取，发布任务还检查签名身份和写入权限；失败时先核对 package 设置及签名密钥。

## 资源和故障记录

依赖构建一次执行一个 derivation，供它使用全部可用 CPU，避免多个编译器同时争抢内存。CI 使用自己的 Nix 配置；runner、超时、磁盘清理和 swap 设置集中在[验证工作流](../.github/workflows/ci.yml)，VM 的资源需求由[测试定义](../tests/vm)负责。

容器的 `nofile` 上限需要保持有界：gawk 会据此分配管道管理数组，接近无限的默认值可能导致数十 GiB 的内存分配。调整 runner 或容器启动方式时，应保留工作流中的这项限制。

发生失败时，先看运行页面的 summary，再下载 `diagnostics-<host>-<attempt>` artifact。诊断文件保留七天：

| 记录 | 用途 |
| --- | --- |
| summary、`timings.jsonl` | 查看各阶段墙钟时间及耗时依赖，区分实际执行与缓存复用 |
| `resources.jsonl`、`oom-*.log` | 对照 CPU、内存、swap、磁盘与 OOM 记录判断资源瓶颈 |
| `oranc.log`、`monitor.log` | 排查缓存代理及资源采集故障 |

SIGKILL 本身不能证明 OOM，需要结合资源记录与内核日志。构建活动结束也不等于构建成功；未结束的活动只记录到命令退出为止。VM 耗时的比较方式见[完整验收与计时](validation.md#完整验收与计时)。失败时仍收集诊断并释放本轮存储。

缓存的发布范围、失败重试和历史对象保留见[缓存指南](cache.md#发布范围)。
