# 构建缓存

仓库通过 `infra/` 子 flake 的 `lib.cache`（[infra/nix/cache.nix](../infra/nix/cache.nix) 与 [infra/nix/public-caches.nix](../infra/nix/public-caches.nix)）为 laptop 主机、开发容器、CI 及下游仓库提供统一的公共 HTTPS 缓存与签名 GHCR 二进制缓存（[oranc](https://github.com/linyinfeng/oranc)）配置。本仓缓存身份在 [cache-identity.json](../nix/cache-identity.json) 声明，连接配置与再分发策略分别由 [cache-config.nix](../nix/cache-config.nix) 和 [cache-policy.nix](../nix/cache-policy.nix) 生成。

## 查看状态与客户端配置

### NixOS 主机与容器

启用 `site.cache` 的主机自动配置本地 `oranc` 代理、Nix substituters 与签名公钥（当监听地址位于 Docker 网桥且启用了 Docker 时，`oranc.service` 排在 `docker.service` 之后启动；默认开启 `fallback = true` 与 5 秒连接超时，本地代理不可达时自动回退）。同时，启用 `site.containers` 的主机通过 [modules/services/containers.nix](../modules/services/containers.nix) 在容器网桥 `172.17.0.1:37516` 运行只读 `harmonia` 服务（`FreeBind` 套接字激活并随 `docker.service` 预热，`PrivateNetwork` 隔离进程网络，nftables 仅放行回环与本地容器网桥），直接向本机开发容器导出已验签的宿主 `/nix/store`：

```sh
systemctl status oranc harmonia.socket harmonia.service
journalctl -u oranc -u harmonia -n 50 --no-pager
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
cache_url=$(nix eval --store dummy:// --raw --file nix/cache-config.nix local.uri)
nix store info --store "$cache_url"
curl -fsS http://172.17.0.1:37516/nix-cache-info
```

### 开发容器及其他 Nix 客户端

开发容器按镜像内嵌的 `devcontainers.nix.cache-layout` 契约挂载宿主持久化的 `~/.local/state/devcontainers/cache/<id>`（其中 `nix` 对应容器内 `/var/cache/devcontainer-nix`，其余语言与构建工具池分别对应各自缓存目录）并连接宿主网桥时，Nix 按优先级依次复用镜像层、跨容器共享 `file://` 缓存、宿主 `harmonia`（`172.17.0.1:37516`）与 `oranc`（`172.17.0.1:37515`）。其他通用 Nix 客户端在仓库根目录通过 [scripts/nix-cache.sh](../scripts/nix-cache.sh)（委托 [infra/scripts/nix-cache.sh](../infra/scripts/nix-cache.sh)）查看或安装持久配置：

```sh
bash scripts/nix-cache.sh print
bash scripts/nix-cache.sh install
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix develop .#laptop
```

无本地代理的环境使用 `bash scripts/nix-cache.sh install --public-only`。非 NixOS 的多用户 Nix daemon 环境由管理员执行 `sudo bash scripts/nix-cache.sh install --system && sudo systemctl restart nix-daemon.service`。

### 本地验证与升级 `oranc`

`oranc` 在 `infra/flake.lock` 中保留独立的上游构建锁，使日常升级公共 `nixpkgs` 时 `oranc` 输出路径与 CI 启动缓存键保持稳定。单独升级并验证：

```sh
nix flake update oranc --flake ./infra
nix flake update infra
nix build --no-link ./infra#oranc .#oranc
ci_tools=$(nix build --no-link --print-out-paths ./infra#ci-tools)
PATH="$ci_tools/bin:$PATH" python3 -m tests.integration.cache --nixpkgs-input nixpkgs
PATH="$ci_tools/bin:$PATH" python3 -m tests.integration.cache --nixpkgs-input nixpkgs-remote
```

## 本地验签溯源与再分发过滤

[nix/ci.nix](../nix/ci.nix) 声明构建组与缓存策略，[nix/cache-policy.nix](../nix/cache-policy.nix)（调用 `inputs.infra.lib.cache.mkPolicy`）与 [infra/ci/cache.py](../infra/ci/cache.py) 共同完成再分发裁剪、可信签名分流与增量上传：

- **源码树、受限载荷隔离与发布种子筛选**：`flake.outPath` 始终列入 `excludedPaths`；`mkPolicy` 对候选包、`extraRestricted` 与 `extraExcluded`（含 `anytype`、`anytype-heart`、`google-chrome`、`vscode`、`vscodeServer` 及其外层包装）递归解包 `passthru.unwrapped` / `unwrapped` 检查可再分发性，并对 `bundles` 声明的聚合镜像做输入图传染分析，排除内嵌受限内容的产物。`prepare_inventory()` 选择允许二进制替代（`allowSubstitutes`）、非本地拼装（`!preferLocalBuild`）且非中间 `kvm` 建盘步骤（仅保留 `manifest.roots` 顶层任务中的 `kvm` 测试结果）的 derivation 输出作为发布种子。
- **引用图边界截断**：`Publisher.discover()` 递归展开可替代产物的运行时 `references` 以保证二进制缓存闭包完整，遇到 `excluded` 路径时记录排除统计并立即停止展开其内部引用。
- **本地 `path-info` Ed25519 验签分流**：`nix build` 在 `require-sigs = true` 下统一从公共只读 substituters、共享缓存与目标缓存并发恢复已有产物并写入 `/nix/var/nix/db/db.sqlite`。发布器读取本地 `nix path-info --json` 元数据，在内存中以 `trustedPublicKeys` 校验每条路径的 Ed25519 指纹签名：
  - 通过当前目标缓存公钥验签的路径计入 `targetHits` 并跳过上传；
  - 通过其他可信上游或共享缓存公钥验签的路径计入 `upstreamHits` 并跳过上传；
  - 无可信签名的本地构建路径（含密钥轮换后仅带旧签名的路径）列入待上传队列，常规产物按 NAR 体积从大到小在受控内存预算内并发推送，大体积产物（`> 512 MiB`）在检查点阶段逐条由独立子进程串行推送，统一通过 `oranc push --no-closure --already-signed --excluded-signing-key-pattern 'a^' --zstd-level 3 --max-retry 3` 签名写入目标 GHCR 仓库。

## 旁路增量与阶段末双模式

`nix-ci cache` 同时支持后台增量模式（`mode = "incremental"`，由 `start` / `checkpoint` / `stop` 配合独立旁路容器边构建边上传）与阶段末一次性发布模式（`mode = "end-of-phase"`，由 `nix-ci cache publish` 在构建验收完成后统一探测上传）。每批上传成功后原子更新 `<state>/published-paths.json`。

## 签名密钥管理

首次创建 Ed25519 缓存签名密钥对（已有缓存身份时直接复用原私钥，轮换时使用新 key-name 如 `nixos-config-2`）：

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

将输出的公钥填入 `nix/cache-identity.json` 的 `publicKey`，并将私钥离线备份后写入 GitHub Actions Secret：

```sh
signing_key="${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config/cache/nixos-config-1.secret"
gh secret set NIX_CACHE_SIGNING_KEY < "$signing_key"
```
