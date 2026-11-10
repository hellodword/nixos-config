# 自动更新、验收与缓存发布

[验证工作流](../.github/workflows/ci.yml)负责构建、测试和缓存发布；[更新工作流](../.github/workflows/update.yml)负责选择新的上游版本，并在验证成功后发布候选提交。

## 入口和候选提交

| 入口 | 行为 |
| --- | --- |
| push 到 `master` | 验证该提交，构建期间增量发布签名缓存，在阶段结束时等待发布完成 |
| 手动运行 Verify and cache | 默认验证所选 ref；只有 master 发布缓存 |
| 在 master 手动勾选 `initialize-cache` | 只创建缓存索引，供首次设置 package；不执行系统构建和 VM |
| 定时运行，或在 master 手动运行 Update flake inputs | 更新指定输入；需要候选时创建提交并调用验证工作流 |

更新时间与输入列表见[更新工作流](../.github/workflows/update.yml)。本地更新及按需升级见[主机维护](maintenance.md#更新与验证)。

GeoSite、GeoIP 的初始快照随其他输入更新。只有这两个输入的版本变化时，本轮结束；包含其他输入或规则来源声明变化时，将全部变化放入同一候选。运行中规则的更新与确认见[网络规则](network.md#规则来源与更新)。

更新任务先创建候选提交并交给验证任务。构建针对最终提交，系统的 `configurationRevision` 与验收 SHA 一致；失败候选不推送。

所有 host 成功后，工作流创建 PR，将 master 快进到已验证的提交，再删除候选分支。若 master 已前进而无法快进，本轮关闭 PR 并删除分支，下一次从新基线开始。仓库分支策略必须允许这种合并方式；调整保护规则时需核对[合并实现](../.github/ci/update.py)。

## 主机与执行顺序

验证工作流的 `matrix.host` 选择需要验收的主机，当前支持 `x86_64-linux`。主机依次执行，某台失败仍继续检查其余主机；自动更新等待全部成功才能合并。新增机器见[增加主机](maintenance.md#增加主机)。

| 步骤 | 内容 |
| --- | --- |
| 准备 | 清理指定 runner SDK、建立 swap、KVM、独立 Nix store 和资源采样 |
| 缓存与工具 | 确认项目缓存可匿名读取，准备开发工具；发布任务核对签名身份和写入权限 |
| 静态检查与集成 | 工作流、Shell、Nix 格式检查；读取实际发布配置，执行 OCI 缓存集成 |
| 清单求值 | 求值所选系统、开发环境、检查与 VM driver，生成构建及发布清单 |
| 依赖构建 | 构建受限依赖、所选系统、开发环境、领域检查和全部 VM driver；后台上传成功产物 |
| 依赖发布收尾 | 补齐已有产物和运行时引用，上传大对象并等待队列完成；构建失败也保留成功产物 |
| VM 第一组 | network 与 backup 依次运行 |
| VM 第二组 | desktop 单独运行 |
| VM 第三组 | applications 单独运行 |
| 汇总与发布收尾 | 四组 VM 全部通过才生成聚合结果；完成剩余产物的发布并结束上传进程 |

同一个 host 的步骤共享 runner、容器和 Nix store。不同 host 使用独立 runner，通过 GHCR 复用相同依赖和测试结果。本地求值要求、清单复核命令与检查范围见[验证指南](validation.md)。

GitHub Actions bootstrap cache 保存 oranc 的运行闭包，用于尽快启动代理。代理就绪后，开发环境和项目构建通过[GHCR 缓存](cache.md#发布范围)复用依赖。master 在 oranc 准备完成后立即保存 bootstrap cache，因此后续测试失败也能保留它。未命中或读取失败时照常构建；超过[工作流](../.github/workflows/ci.yml)中的容量上限时跳过保存，写入失败也不影响后续验证。运行 summary 中的 Oranc bootstrap cache 显示命中、大小和跳过原因，保存结果见对应步骤日志。

新的提交不会中断正在运行的验证；等待中的验证只保留最新一项，因此连续 push 的每个中间提交不一定都会执行。更新与验证使用独立的并发组，避免调用方占用验证需要的组。排队规则见 [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)。

master push 和自动更新在构建、依赖缓存发布均成功后进入 VM 验证。后台上传失败会在当前构建阶段结束后的发布检查点报告，随后收集诊断；进入 VM 后，某组失败仍继续其余组，并在收尾发布已完成的新产物。手动验证非 master ref 时，构建成功后直接进入 VM。取消任务时有界停止上传进程，已经发布的缓存保留在 GHCR。

GHCR 缓存发布和测试分别报告状态，任意一项失败都会使验证任务失败。缓存可在全部验证完成前发布，其存在不代表验收通过或已经部署。自动更新直接调用验证工作流，因为 [GITHUB_TOKEN 引发的 push](https://docs.github.com/en/actions/concepts/security/github_token)不会再次触发 push 工作流。

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
| summary、`timings.jsonl` | 查看各阶段墙钟时间及耗时依赖，区分实际执行与缓存复用；查看后台查询、上传数量与体积，以及发布检查点的等待时间和结果 |
| `publication-paths.jsonl` | 核对每次发布选中的路径、再分发排除项、公共及项目缓存命中，以及待上传路径的 NAR 大小 |
| `publisher.log`、`cache/status.json`、`published-paths.json` | 定位上传进程错误，核对退出状态和本轮成功发布的路径 |
| `resources.jsonl`、`oom-*.log` | 对照 CPU、内存、swap、磁盘与 OOM 记录判断资源瓶颈 |
| `oranc.log`、`monitor.log` | 排查缓存代理及资源采集故障 |
| `vm/<pass>/<check>/` | VM 日志、截图与 OCR 记录，网络观察快照、通知诊断及应用工作流产物；具体目录见 summary 的 VM evidence |

构建目录及权限由 Nix 管理。VM 构建使用 `--keep-failed` 保留失败现场，原目录位置见构建日志，在 runner 生命周期结束时释放。构建进程结束后，工作流将已写出的测试输出收集到诊断 artifact；输出缺失和收集错误在 summary 中单独列出，构建结果照常记录。

后台缓存查询和上传与构建重叠，发布检查点的等待时间反映阶段结束后的剩余工作。比较运行效率时看任务总墙钟时间和检查点等待时间，后台耗时不与构建耗时相加。

SIGKILL 本身不能证明 OOM，需要结合资源记录与内核日志。构建活动结束也不等于构建成功；未结束的活动只记录到命令退出为止。VM 耗时的比较方式见[完整验收与计时](validation.md#完整验收与计时)。

缓存的发布范围、失败重试和历史对象保留见[缓存指南](cache.md#发布范围)。
