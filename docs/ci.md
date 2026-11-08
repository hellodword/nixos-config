# 自动更新、验收与缓存发布

唯一工作流是 [ci.yml](../.github/workflows/ci.yml)。构建、测试、候选提交和发布共享同一个 runner 与 Nix store；本地 push 负责提交代码，GitHub Actions 负责验收与产生公共二进制缓存。

## 触发与更新范围

| 入口 | 行为 |
| --- | --- |
| push 到 `master` | 验收该提交已锁定的依赖，成功后发布缓存 |
| 每日 UTC 19:37，北京时间次日 03:37 | 更新指定输入；锁文件有变化时验收、创建 PR、合并并发布；没有变化时结束 |
| 手动 `check` | 验收所选 revision；只有 `master` 发布缓存 |
| 手动 `update` | 在 `master` 运行自动更新流程；选择其他分支时只验收 |

调度可能受 GitHub 排队影响，cron 是计划时间。更新命令位于 [scripts/ci.sh](../scripts/ci.sh)，范围为：

```text
catppuccin-fcitx5 nixos-hardware plasma-manager sing-box-geosite nixpkgs
reproducible-violentmonkey arkenfox-userjs home-manager nix-index-database
sing-box-geoip vm-test-tools
```

Nix 将上游 revision 写入 `flake.lock`。`flake.nix` 继续声明跟踪来源；oranc、安装相关固定输入及包内固定版本不参与每日更新。

## 验收与提交的关系

候选工作树按以下阶段验收，各阶段共享本轮 Nix store：

| 阶段 | 内容 |
| --- | --- |
| 工具与检查 | actionlint、ShellCheck、Nix 格式检查、真实 OCI 缓存集成，以及构建清单求值 |
| 软件与依赖构建 | 先准备不公开发布的依赖，再构建 laptop2 系统、Home Manager、两个开发 shell、非 VM 检查及全部 VM driver |
| 第一组 VM | network 与 desktop 并行 |
| 第二组 VM | applications 与 backup 并行 |
| E2E 汇总 | 构建 `checks.x86_64-linux.e2e`，生成可发布路径清单 |

VM 的 `.driver` 包含测试脚本、客体系统和运行依赖，构建它不会启动测试 VM。软件编译与依赖包自身的测试计入构建准备；VM 阶段使用已准备好的输入。`e2e` 继续要求完整生产系统、Home Manager 和全部检查结果。

第一次构建之前，`scripts/ci.sh` 通过纯 Nix 配置汇总层加载 `flake.nix` 声明的公共缓存 URL 和公钥，因而 oranc 和开发 shell 自身也能使用这些缓存。随后启动本轮容器内的回环 oranc，项目缓存可读时加入同一组 Nix 设置。Actions 使用本轮代理，开发容器使用 laptop2 的宿主代理；两者共享仓库和签名身份。[缓存指南](cache.md)说明完整的声明与应用方式。

成功后只提交 `flake.lock`。系统的 `configurationRevision` 包含 Git revision，因此提交后重新求值构建清单，按相同构建与 VM 阶段验证正式 revision；未改变 derivation 的 VM 结果直接复用。最终提交重新构建成功后，`gh` 创建 PR，并通过 Git refs API 的 `force=false` 将 `master` 快进到这个精确提交。GitHub 确认 PR 为 merged 后删除自动分支。这样主机取得的系统 revision 与验收并发布的 revision 相同。

若验收期间 `master` 前进，非快进更新被拒绝，本轮 PR 关闭，自动分支删除；后续更新从新的基线重新验收。流程依赖允许直接快进的分支策略；启用新的保护规则时需重新设计合并方式，不能绕过规则。

合并后在同一轮发布缓存。[GITHUB_TOKEN 引发的 push 不会再触发普通 push 工作流](https://docs.github.com/en/actions/concepts/security/github_token)，因此发布不依赖另一轮运行。若发布失败，已合并的配置保留；在当前 `master` 手动运行 `check`，重新验收并补齐缓存。签名公钥、对象路径与 NAR 哈希决定缓存身份，历史对象可继续使用。

## 首次启用

1. 在 push 之前将仓库设为 public。Actions 的允许策略只需允许 GitHub 创建的 actions；工作流仅使用 `actions/checkout@v7`。
2. 在 Settings → Actions → General 的 Workflow permissions 中允许工作流创建 PR。工作流声明 `contents: write`、`pull-requests: write`、`packages: write`；checkout 不保存凭据，令牌只传给 PR/合并和发布步骤。
3. 将仓库外的签名私钥设置为 repository secret `NIX_CACHE_SIGNING_KEY`。使用与 [nix/cache-identity.json](../nix/cache-identity.json) 公钥配套的已有私钥；首次创建缓存身份的命令见[签名密钥](#签名密钥)。先核对公钥再上传：

   ```sh
   signing_key="${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config/cache/nixos-config-1.secret"
   nix key convert-secret-to-public < "$signing_key"
   gh secret set NIX_CACHE_SIGNING_KEY --repo hellodword/nixos-config < "$signing_key"
   ```

   私钥保留在 0600 的仓库外文件中并妥善备份；不写入 Git、Nix store、日志或构建产物。更换密钥时同步可信公钥与 GitHub secret，并考虑旧缓存的签名信任。
4. 首轮发布后检查 `ghcr.io/hellodword/nixos-config` 的 package 设置：visibility 为 **Public**，关联本仓库，Actions 有写入权限。GHCR 首次创建的包默认 private；公开后 laptop2 和 CI 均可匿名读取，无需 PAT。首轮项目缓存尚不可访问时，CI 使用已配置的公共缓存和本地构建。
5. 首轮成功后在 `master` 手动运行 `check`，确认相同哈希的 VM 结果和自定义构建产物从缓存恢复；同时查看资源记录和发布耗时。laptop2 切换到本配置后，后续 Nix 命令使用持久配置中的缓存，无需附加参数。

首次 GitHub 执行负责验收真实 GITHUB_TOKEN 权限、包的匿名访问、runner 资源上限和完整 E2E；本地集成使用临时 registry 与合成密钥。

## 签名密钥

`NIX_CACHE_SIGNING_KEY` 保存 Nix 的 Ed25519 缓存签名私钥；CI 用它签名，消费者通过 `nix/cache-identity.json` 中的公钥验证构建产物。私钥由 [`nix key generate-secret`](https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-key-generate-secret) 随机生成。`--key-name` 是签名标识，相同名称再次生成也会得到另一对密钥，无法据此恢复原私钥。

已有缓存身份应复用配套私钥。以下命令用于首次创建，私钥文件权限为 0600；`set -C` 保护同名现有文件，括号将 shell 设置限制在本次操作内：

```sh
(
  set -euC
  umask 077
  signing_key="${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config/cache/nixos-config-1.secret"
  mkdir -p -- "$(dirname -- "$signing_key")"
  nix key generate-secret --key-name nixos-config-1 > "$signing_key"
  nix key convert-secret-to-public < "$signing_key"
)
```

最后输出的是公钥，将其填写到 `nix/cache-identity.json` 的 `publicKey`；私钥文件的完整内容按首次启用步骤上传到 GitHub secret。备份仓库外的私钥文件以便迁移和恢复。正式轮换时采用新的名称与文件名（例如 `nixos-config-2`），协调更新 CI 私钥和消费者信任，并安排旧缓存的签名过渡。

## runner 资源与并发

工作流固定 `ubuntu-24.04` x64，使用官方 Nix 2.34.9 容器和 KVM，超时 330 分钟。先在独立进程中求值构建根，再按已确定的 derivation 构建，让构建器运行时释放完整配置的求值内存。公开仓库的[标准 Linux runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)提供 4 CPU 和 16 GB 内存。

资源参数随阶段传给 Nix，不写入全局 `NIX_CONFIG`：软件构建最多两个任务，每项使用一半可用 CPU，在当前 runner 上为 `--max-jobs 2 --cores 2`。构建清单来自生产系统和检查的依赖图。四组 VM 按上述两批执行，保留各测试定义中的 guest CPU、内存和超时。第一批客体配置合计峰值约 9.5 GiB，第二批约 10 GiB，还需容纳 QEMU 和宿主进程开销。

[scripts/ci/runner.sh](../scripts/ci/runner.sh) 只清理列出的 Android、.NET、Haskell、Swift 和 Boost SDK 目录，保留 Docker、Git、gh、runner Node 与 KVM。保留 runner 原有 swap，并增加本轮专属的 8 GiB swap 文件以缓冲内存峰值。`/nix` 使用本轮专属 Docker named volume，初次挂载复制镜像的 Nix store；构建临时目录绑定 runner 文件系统，避免大型写入进入容器可写层。收尾先释放容器与 volume，再停用并删除本轮创建的 swap。没有 Nix store、VM 磁盘或大体积 Actions artifact 的二次上传。

整个工作流使用同一 concurrency group，`cancel-in-progress=false`。一个运行中的任务继续完成，队列仅保留最新 pending 任务，避免同时运行多组 VM 或多个发布者。[GitHub concurrency 语义](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)并不保证每个中间提交都会单独运行。

oranc 使用单并发、zstd level 3 与内置有界重试。GHCR 的[容器限制](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)包括单层 10 GB 与单次上传 10 分钟；没有为未知的请求速率设置额外调度器。服务端拒绝或超时会使发布步骤失败，详细错误留在该步骤日志中。公开镜像当前的存储与流量政策见 [GitHub Packages 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-packages)。

## 耗时与故障诊断

Actions summary 分别展示工具检查、软件与依赖构建、两批 VM、最终 revision 验证和缓存发布的墙钟耗时。Nix 分组表是对应阶段的明细，不能与外层阶段重复相加。候选工作树与提交后的执行使用不同标签。

[scripts/ci/build.py](../scripts/ci/build.py) 消费独立的 Nix JSON 日志流，以单调时钟记录实际构建和缓存恢复事件，并保留常规构建日志。每个 VM 结果区分 `executed`、`local reuse` 和 `cache restored`；实际执行耗时包含 VM 构建器中的客体启动、测试和收尾，缓存复用不填写执行耗时。只有全部必需 VM 本轮执行并成功时，报告才标记为完整重新执行。两批 VM 的墙钟时间之和表示 VM 阶段耗时，各项并行测试的耗时不能直接相加作为墙钟时间。

runner 每 30 秒采集 CPU 使用率、可用内存、swap 与磁盘空间，同时读取容器 cgroup 内存峰值和 OOM 计数。删除容器前补采一次，并保存本轮内核与 systemd-oomd 记录；采样峰值与 cgroup 记录的峰值分别标注。记录保存在本轮临时状态目录，收尾输出到任务日志和 summary。每条 Nix 命令的 JSON 事件文件在统计后释放。

失败报告保留已记录的阶段、命令、退出码和信号。`SIGKILL` 表明进程被强制结束；确认 OOM 需要结合 cgroup 计数和内核或 systemd-oomd 记录。单独的 `Docker.State.OOMKilled=false` 不能排除容器中的子进程曾被 OOM killer 结束。失败会阻止后续提交、合并或缓存发布步骤。

首次完整 Actions 执行用于验收真实 runner 的资源和权限，并建立软件构建、实际 VM 执行与发布的耗时基线。相同 derivation 的后续复用记录用于评估缓存收益，不能替代完整重新执行的耗时基线。
