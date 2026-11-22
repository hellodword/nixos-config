# 构建缓存

仓库通过 `infra/` 子 flake 的 `lib.cache`（[infra/nix/cache.nix](../infra/nix/cache.nix) 与 [infra/nix/public-caches.nix](../infra/nix/public-caches.nix)）为 laptop 主机、开发容器、CI 及下游仓库提供统一的公共 HTTPS 缓存与签名 GHCR 二进制缓存（[oranc](https://github.com/linyinfeng/oranc)）配置。本仓缓存身份在 [cache-identity.json](../nix/cache-identity.json) 声明，连接配置与再分发策略分别由 [cache-config.nix](../nix/cache-config.nix) 和 [cache-policy.nix](../nix/cache-policy.nix) 生成。

## 查看状态与客户端配置

### NixOS 主机与容器

启用 `site.cache` 的主机自动配置本地 `oranc` 代理、Nix substituters 与签名公钥（当监听地址位于 Docker 网桥且启用了 Docker 时，`oranc.service` 排在 `docker.service` 之后启动；默认开启 `fallback = true` 与 5 秒连接超时，本地代理不可达时自动回退）：

```sh
systemctl status oranc
journalctl -u oranc -n 50 --no-pager
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
cache_url=$(nix eval --store dummy:// --raw --file nix/cache-config.nix local.uri)
nix store info --store "$cache_url"
```

### 开发容器及其他 Nix 客户端

宿主机提供可达的 `oranc` 代理后，在仓库根目录通过 [scripts/nix-cache.sh](../scripts/nix-cache.sh)（委托 [infra/scripts/nix-cache.sh](../infra/scripts/nix-cache.sh)）查看或安装持久配置：

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

## 远端 `.narinfo` 探测与再分发过滤

[nix/ci.nix](../nix/ci.nix) 声明构建组与缓存策略，[nix/cache-policy.nix](../nix/cache-policy.nix)（调用 `inputs.infra.lib.cache.mkPolicy`）与 [infra/ci/cache.py](../infra/ci/cache.py) 共同执行再分发裁剪与远端去重上传：

- **源码树与受限载荷隔离**：`flake.outPath` 始终列入 `excludedPaths`；`mkPolicy` 对候选包与 `extraRestricted`（含 `anytype`、`anytype-heart`、`google-chrome`、`vscode` 与 `vscodeServer`）递归解包 `passthru.unwrapped` / `unwrapped` 检查许可证可再分发性，并对 `bundles`（测试容器镜像与 VM 启动磁盘）做输入图传染分析，一并排除复制了受限内容的中间产物。
- **引用图边界截断**：`Publisher.discover()` 遇到 `excluded` 路径时记录排除统计并立即停止展开其内部运行时 `references`。
- **直接校验远端 `.narinfo` 与 Ed25519 签名**：上传器不将本地 `/nix/store` SQLite 中的签名视为远端已缓存依据，而是使用并发线程池直接向写入目标及全部生效只读 substituters 请求 `/<store-hash>.narinfo`，验证 `StorePath` 与可信公钥的 Ed25519 指纹签名：
  - 任一可信源返回有效签名 `200` 即判定命中（区分 `targetHits` 与 `upstreamHits`）；
  - 全部可信源返回 `404`（或 `targetUri` 仅存旧密钥签名）时使用 `oranc push --no-closure --already-signed --excluded-signing-key-pattern 'a^' --zstd-level 3 --max-retry 3` 精确签名上传，并在每批上传后回查目标缓存 `.narinfo` 验签通过后再记录成功清单（即使本地已有 `cache.nixos.org-1` 或项目签名而远端 `404` 也会自动补传）；
  - 若某个待决路径在已响应源上为 `404`，但任一只读源返回损坏/未受信签名的 `200` 响应，或经指数退避重试后仍处于网络超时 / `5xx` 异常，则拒绝盲目将该路径上传至个人 GHCR 并在收尾阶段返回非零退出码留待重试。

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
