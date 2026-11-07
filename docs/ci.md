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

候选工作树先完成 actionlint、ShellCheck、Nix 格式检查和真实 OCI 缓存集成，再构建完整 `checks.x86_64-linux.e2e` 以及两个开发 shell。E2E 包含 laptop2 系统、Home Manager 和全部既有检查，四组 VM 由单任务 Nix 构建器顺序运行。

成功后只提交 `flake.lock`。系统的 `configurationRevision` 包含 Git revision，因此提交后再次构建正式入口；未改变 derivation 的 VM 结果直接复用。最终提交重新构建成功后，`gh` 创建 PR，并通过 Git refs API 的 `force=false` 将 `master` 快进到这个精确提交。GitHub 确认 PR 为 merged 后删除自动分支。这样主机取得的系统 revision 与验收并发布的 revision 相同。

若验收期间 `master` 前进，非快进更新被拒绝，本轮 PR 关闭，自动分支删除；后续更新从新的基线重新验收。流程依赖允许直接快进的分支策略；启用新的保护规则时需重新设计合并方式，不能绕过规则。

合并后在同一轮发布缓存。[GITHUB_TOKEN 引发的 push 不会再触发普通 push 工作流](https://docs.github.com/en/actions/concepts/security/github_token)，因此发布不依赖另一轮运行。若发布失败，已合并的配置保留；在当前 `master` 手动运行 `check`，重新验收并补齐缓存。签名公钥、对象路径与 NAR 哈希决定缓存身份，历史对象可继续使用。

## 首次启用

1. 在 push 之前将仓库设为 public。Actions 的允许策略只需允许 GitHub 创建的 actions；工作流仅使用 `actions/checkout@v7`。
2. 在 Settings → Actions → General 的 Workflow permissions 中允许工作流创建 PR。工作流声明 `contents: write`、`pull-requests: write`、`packages: write`；checkout 不保存凭据，令牌只传给 PR/合并和发布步骤。
3. 将仓库外的签名私钥设置为 repository secret `NIX_CACHE_SIGNING_KEY`。先验证它对应 [nix/cache-identity.json](../nix/cache-identity.json) 的公钥：

   ```sh
   signing_key="${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config/cache/nixos-config-1.secret"
   nix key convert-secret-to-public < "$signing_key"
   gh secret set NIX_CACHE_SIGNING_KEY --repo hellodword/nixos-config < "$signing_key"
   ```

   私钥保留在 0600 的仓库外文件中并妥善备份；不写入 Git、Nix store、日志或构建产物。更换密钥时同步可信公钥与 GitHub secret，并考虑旧缓存的签名信任。
4. 首轮发布后检查 `ghcr.io/hellodword/nixos-config` 的 package 设置：visibility 为 **Public**，关联本仓库，Actions 有写入权限。GHCR 首次创建的包默认 private；公开后 laptop2 和 CI 均可匿名读取，无需 PAT。首轮缓存尚不可访问时，CI 使用官方缓存和本地构建。
5. 首轮成功后在 `master` 手动运行 `check`，确认相同哈希的 VM 结果和自定义构建产物从缓存恢复；同时查看资源记录和发布耗时。laptop2 切换到本配置后，后续 Nix 命令使用持久配置中的缓存，无需附加参数。

首次 GitHub 执行负责验收真实 GITHUB_TOKEN 权限、包的匿名访问、runner 资源上限和完整 E2E；本地集成使用临时 registry 与合成密钥。

## runner 资源与并发

工作流固定 `ubuntu-24.04` x64，使用官方 Nix 2.34.9 容器和 KVM；超时 330 分钟，Nix `max-jobs=1`、`cores=2`。先在独立进程中求值构建根，再按已确定的 derivation 构建，让 VM 运行时释放完整配置的求值内存。公开仓库的[标准 Linux runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)有 16 GiB 内存和有限的可用磁盘，完整桌面与 VM 构建需要释放预装 SDK 占用。

[scripts/ci/runner.sh](../scripts/ci/runner.sh) 只清理列出的 Android、.NET、Haskell、Swift 和 Boost SDK 目录，保留 Docker、Git、gh、runner Node 与 KVM。`/nix` 使用本轮专属 Docker named volume，初次挂载复制镜像的 Nix store；构建临时目录绑定 runner 文件系统，避免大型写入进入容器可写层。每分钟记录磁盘使用量，并在收尾输出记录、释放本轮容器与 volume。没有 Nix store、VM 磁盘或大体积 Actions artifact 的二次上传。

整个工作流使用同一 concurrency group，`cancel-in-progress=false`。一个运行中的任务继续完成，队列仅保留最新 pending 任务，避免同时运行多组 VM 或多个发布者。[GitHub concurrency 语义](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)并不保证每个中间提交都会单独运行。

oranc 使用单并发、zstd level 3 与内置有界重试。GHCR 的[容器限制](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)包括单层 10 GB 与单次上传 10 分钟；没有为未知的请求速率设置额外调度器。服务端拒绝或超时会使发布步骤失败，详细错误留在该步骤日志中。公开镜像当前的存储与流量政策见 [GitHub Packages 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-packages)。
