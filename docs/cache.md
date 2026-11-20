# 构建缓存

项目为 laptop 主机、开发容器与 CI 提供统一的公共缓存 + GHCR 二进制缓存（[oranc](https://github.com/linyinfeng/oranc)）配置。公共缓存在 [public-caches.nix](../nix/public-caches.nix) 声明，项目缓存身份与监听端口分别在 [cache-identity.json](../nix/cache-identity.json) 和 [cache-config.nix](../nix/cache-config.nix) 管理。

## 查看状态与客户端配置

### NixOS 主机与容器

启用 `site.cache` 的主机自动配置本地 `oranc` 代理、Nix substituters 与签名公钥（当监听地址位于 Docker 网桥且启用了 Docker 时，`cache.nix` 自动将 `oranc.service` 排在 `docker.service` 之后启动；同时默认开启 `fallback = true` 与 5 秒连接超时，本地代理暂不可用时自动回退构建）：

```sh
systemctl status oranc
journalctl -u oranc -n 50 --no-pager
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
cache_url=$(nix eval --raw --file nix/cache-config.nix local.uri)
nix store info --store "$cache_url"
```

### 开发容器及其他 Nix 客户端

宿主机提供可达的 `oranc` 代理后，在开发容器或外部客户端的仓库根目录安装持久配置：

```sh
bash scripts/nix-cache.sh print
bash scripts/nix-cache.sh install
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix develop .#laptop
```

无法连接宿主代理时使用 `bash scripts/nix-cache.sh install --public-only`。非 NixOS 的多用户 Nix daemon 环境由管理员执行 `sudo bash scripts/nix-cache.sh install --system && sudo systemctl restart nix-daemon.service`。

### 本地验证与升级 `oranc`

`oranc` 在 `flake.lock` 中保留独立的构建输入锁，避免日常 `nixpkgs` 升级破坏 GitHub Actions 的启动缓存命中。单独升级并验证：

```sh
nix flake update oranc
nix build --no-link .#oranc
ci_tools=$(nix build --no-link --print-out-paths --impure --expr \
  'import ./nix/ci-tools.nix { flake = builtins.getFlake ("git+file://" + toString ./.); scope = "laptop"; }')
PATH="$ci_tools/bin:$PATH" python3 -m tests.integration.cache --nixpkgs-input nixpkgs
```

## 发布范围与再分发过滤

[nix/ci.nix](../nix/ci.nix) 收集当前范围（`laptop` 或 `remote`）的构建根，[nix/cache-policy.nix](../nix/cache-policy.nix) 与 [.github/ci/cache.py](../.github/ci/cache.py) 共同执行再分发过滤：

- **源码树隔离**：`inputs.self.outPath` 始终列入 `excludedPaths`，防止仓库源码（含加密 `.sops.yaml` 与硬件标识）上传至不可删的公开 GHCR；客户端求值 Flake 时已在本地 `/nix/store` 写入同一源码树，因此从缓存恢复系统配置不受影响。
- **穿透解包与双范围一致扫描**：`cache-policy.nix` 对 `laptop` 与 `remote` 统一执行许可证扫描，递归解包 `passthru.unwrapped`（如 Firejail 或 XWayland 包装器）并显式纳入受限运行时依赖（如 `anytype`、`anytype-heart`、`google-chrome`、`vscode`）。
- **引用图截断**：`Publisher.discover()` 在记录命中 `excludedPaths` 的候选统计后，立即停止向被排除路径的内部 `references` 继续展开，阻断非可再分发载荷经上层环境或包装脚本泄露到公开缓存。

CI 先构建受限依赖再执行或恢复 VM 测试结果；公开缓存包含可再分发的自定义包、开发 shell（`laptop` / `vps`）、公开合成配置及通过验收的 VM 测试结果。首次探测未初始化的 GHCR package 时直接请求 `nix-cache-info`（避免在空仓库上执行 `nix store info` 触发索引写入错误），初始化流程见 [CI 首次启用](ci.md#首次启用步骤)。

## 旁路发布隔离、重试与历史保留

在 GitHub Actions 中，构建容器 `nixos-ci` 以只读方式挂载仓库源码且不持有任何发布凭据；`ORANC_SIGNING_KEY`、`ORANC_USERNAME` 与 `ORANC_PASSWORD` 仅注入独立 PID 与环境变量命名空间的旁路容器 `nixos-ci-publisher`。两者共享 `nixos-ci-store:/nix` 卷，并通过 `/ci/cache/requests` 队列与检查点文件通信。

发布进程复用本轮已扫描路径及公共/项目缓存签名，构建期间单路上传普通对象，检查点阶段先逐个上传大对象再并发清空剩余普通队列；历史 GHCR 对象持续保留以支持旧系统代次与缓存复用。

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
