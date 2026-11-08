# 自动更新、验收与缓存发布

[验证工作流](../.github/workflows/ci.yml)负责构建、测试和缓存发布；[更新工作流](../.github/workflows/update.yml)负责选择新的上游版本，并在验证成功后发布候选提交。

## 入口和候选提交

| 入口 | 行为 |
| --- | --- |
| push 到 `master` | 验证该提交，成功后发布签名缓存 |
| 手动运行 Verify and cache | 验证所选 ref；只有 master 发布缓存 |
| 每日 UTC 19:37，或在 master 手动运行 Update flake inputs | 更新指定输入；无变化则结束，有变化则准备候选提交并调用验证工作流 |

更新列表直接写在更新工作流的 `nix flake update` 命令中。Nix 将 revision 写入 `flake.lock`。安装相关固定输入、oranc 和可选远端 VM 客户端按需升级，不参加每日更新。

更新任务先在 runner 上创建本地提交，以 Git bundle 和 SHA 将它交给验证任务。这个 bundle 只携带相对基线新增的 Git 对象。构建针对最终提交，系统的 `configurationRevision` 与验收 SHA 一致；失败候选不推送。

所有 host 成功后，合并任务推送候选分支、通过 `gh` 创建 PR，再使用 Git refs API 的 `force=false` 将 master 快进到已验证的提交。GitHub 确认 PR 合并后删除分支。若 master 已前进而无法快进，本轮关闭 PR 并删除分支，下一次从新基线开始；不覆盖并发提交。仓库分支策略必须允许这条路径，启用新的保护规则时需重新安排合并方式。

## 主机与执行顺序

验证工作流的 `matrix.host` 是主机清单，目前为 `[laptop2]`，构建与 VM 场景面向 `x86_64-linux`。矩阵使用 `max-parallel: 1` 和 `fail-fast: false`：每台主机依次完成自己的验收和缓存发布，某台失败仍继续检查其余主机；自动更新必须等待全部成功才能合并。

| 步骤 | 内容 |
| --- | --- |
| 准备 | 清理指定 runner SDK、建立 swap、KVM、独立 Nix store 和资源采样 |
| 工具和静态检查 | 启动一次 oranc，准备开发环境；运行 actionlint、ShellCheck、Nix 格式及真实 OCI 缓存集成 |
| 求值与构建 | 求值进程退出后，构建受限依赖、所选系统、领域检查和全部 VM driver |
| VM 第一组 | network 与 desktop |
| VM 第二组 | applications 与 backup |
| 汇总与发布 | 聚合四组 VM 结果，筛选并签名发布可再分发路径 |

同一个 host 的步骤共享 runner、容器和 Nix store。不同 host 使用独立 runner，通过 GHCR 复用相同依赖和测试结果；不使用大体积 Actions artifact 搬运 store。Home Manager 属于系统构建，没有单独任务。

验证工作流共用 `nixos-verify` concurrency group，更新入口使用独立的 `nixos-update` group，均设置 `cancel-in-progress: false`。[GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)保留正在运行的任务和最新 pending 任务，不保证每个中间提交都会单独执行。两个 group 分开，调用方不会占着被调用方需要的执行组。

每台主机验证后即可发布缓存，因此更新合并前可能已有成功主机的缓存。缓存使用内容地址和签名，这些产物不等于已经部署。合并由独立任务等待整个矩阵成功。[GITHUB_TOKEN 引发的 push](https://docs.github.com/en/actions/concepts/security/github_token)不会再触发普通 push 工作流，更新验收通过直接调用完成。

## 首次启用

1. 使用 public repo，Actions 允许策略选择允许 GitHub 创建的 actions。工作流使用 `actions/checkout@v7`、`upload-artifact@v7` 和 `download-artifact@v8`。
2. 在 Settings → Actions → General 允许工作流创建 PR。验证任务只需要读取仓库和写入 packages；更新合并任务需要写入 contents 和 pull requests。checkout 不保留凭据。
3. 设置 repository secret `NIX_CACHE_SIGNING_KEY`，复用与仓库公钥配套的私钥。生成、核对和上传命令统一见[缓存签名密钥](cache.md#签名密钥)。
4. 首轮发布后将 GHCR package 设为 Public、关联本仓库并授予 Actions 写入权限。项目缓存首次不可读时，构建会使用已声明的公共缓存和本地构建。
5. 在 master 手动运行验证，核对匿名读取、签名验证与缓存复用；再观察一次更新任务，确认候选提交传递、PR 和精确 SHA 合并正常。

## 资源和故障记录

runner 固定为 `ubuntu-24.04` x64，Nix 容器版本由工作流固定，单个 host 的任务上限为 330 分钟。容器使用任务自己的 Nix 配置，不继承开发机资源限制。构建最多两个任务，每项分配可用 CPU 的相应份额；四组 VM 分两批运行，每批最多两个，客体 CPU、内存和超时仍由测试定义负责。

构建容器通过 `--ulimit nofile=65536:65536` 将每个进程的文件描述符软、硬上限固定为 65,536。gawk 会根据该上限分配管道管理数组，有限上限可避免容器默认值过大时一次分配数十 GiB 内存。该限制属于容器运行参数，依赖包的 derivation 与缓存身份保持不变。

磁盘清理范围直接列在 YAML 中，保留 Docker、Git、gh、runner Node 与 KVM。工作流保留原有 swap，并建立本轮专属的 8 GiB swap；构建临时目录和 store 放在 runner 文件系统上。最终清理先释放容器和 store，再停用并删除本轮 swap。

原生 Actions 步骤给出阶段墙钟时间。`.github/ci/build.py` 读取 Nix 的独立 JSON 事件流，记录实际构建和缓存恢复耗时，summary 区分实际执行、本地复用和远端恢复。`checks.e2e` 只聚合 VM；没有预构建 driver 时，直接构建它仍可能包含依赖构建。

每 30 秒采集 CPU、内存、swap、磁盘及容器 cgroup 数据，收尾补采并读取内核和 systemd-oomd 记录。SIGKILL 本身不能证明 OOM；需要结合这些证据。诊断 artifact 保存七天，仅包含日志和指标。失败时仍执行诊断与存储释放。

缓存声明、许可筛选、发布重试与历史对象保留规则见[缓存](cache.md)。首次真实 Actions 运行负责验证 GitHub 权限、并发及 runner 资源；本地 OCI 集成使用临时 registry 和合成密钥。
