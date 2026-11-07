# OCI 构建缓存

[oranc](https://github.com/linyinfeng/oranc) 将 `ghcr.io/hellodword/nixos-config` 作为标准 Nix binary cache。上游由 `flake.lock` 固定，`packages.x86_64-linux.oranc` 使用项目的 nixpkgs 构建；主机服务、开发 shell 和 CI 复用该包。oranc 不参与每日更新，单独升级使用 `nix flake update oranc`。

## laptop2 的读取方式

laptop2 启用 `site.cache`，[nix/cache-identity.json](../nix/cache-identity.json) 同时提供主机和 CI 使用的仓库名与签名公钥。`oranc.service` 监听 `127.0.0.1:37515`，Nix 的持久配置加入 `http://127.0.0.1:37515/ghcr.io/hellodword/nixos-config`，保留官方缓存并要求签名。

切换到该配置后，`nixos-rebuild`、`nix build` 和 `nix develop` 自动使用缓存，无需每次增加参数。首次切换的构建仍使用旧代次的 Nix 配置。公共 GHCR 包可匿名读取，无需给 laptop2 配置 registry token。服务使用动态用户、只读系统目录、独立临时目录和设备视图，并限制能力、命名空间与内核管理接口。

```sh
systemctl status oranc
journalctl -u oranc
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix store info --store http://127.0.0.1:37515/ghcr.io/hellodword/nixos-config
```

`site.cache` 仍可由其他主机指定仓库、公钥与端口。私有仓库可配置 `netrcFile` 指向 root 所有的 0600 运行时文件，内容形如 `machine 127.0.0.1 login USER password TOKEN`；凭据由 Nix 发送给本机代理，再用于上游认证。凭据内容不进入 Nix store。

## 发布范围

[GitHub 工作流](ci.md)只在验收成功后发布。[nix/cache-policy.nix](../nix/cache-policy.nix) 定义系统、Home Manager、开发 shell、oranc 与 E2E 输出的构建根；[scripts/ci/cache.py](../scripts/ci/cache.py) 从这些 derivation 中选取实际已存在的运行依赖、构建依赖和源码路径，排除 `.drv` 与受限内容。

公开范围包括可再分发的自定义包、配置产物及成功的 Nix VM 测试结果。输入和测试实现均未改变时，Nix 可以直接恢复已通过的测试输出；哈希变化的检查重新执行。oranc 跳过已有官方签名或本缓存签名的路径，使用 `--no-closure` 发布已筛选的清单，避免再次展开出受限依赖。

软件许可证的 `redistributable` 元数据用于筛选主机、Home Manager 和 VS Code 扩展中的直接软件包。VS Code、VS Code Server、Chrome、Remote Containers 扩展、p7zip 的受限输出与下载源不发布。应用测试的开发容器复制了 VS Code Server，其镜像及依赖链上携带受限内容的中间产物也被排除。普通系统包装脚本、符号链接和元数据可以保留对这些路径的引用。

新增软件或将软件复制进其他 bundle 时，需要同步这份清单并审阅许可证；单纯读取 Nix store 引用无法判定文件的再分发权。`unfreeRedistributable` 与禁止再分发的许可分别处理，不会一概排除所有 unfree 软件。

CI 先从原始来源构建被排除的软件及容器，再请求 E2E 结果，保证恢复测试结果时所需的受限依赖已经存在。laptop2 仍自行取得这些应用；部分引用它们的上层产物可能由 Nix 在本地组装，其余可发布依赖继续命中缓存。公开缓存不是完整主机闭包的独立离线副本。

## 签名、重试与历史对象

发布使用运行时的 `NIX_CACHE_SIGNING_KEY`、GITHUB_TOKEN 和 `oranc push`。在任何 registry 写入之前，将私钥推导出的公钥与仓库中声明的公钥核对。私钥不保存在仓库或 Nix 构建环境中；首次配置和密钥交接见 [CI 启用步骤](ci.md#首次启用)。

发布并发为 1，zstd level 为 3，`max-retry=3` 使用锁定版本的内置重试。NAR 上传成功后才写入对应 narinfo。发布失败在 Actions 中单独可见，下一次在 `master` 运行 `check` 可以补齐对象。

历史 GHCR 对象持续保留。narinfo 引用对应 NAR，旧系统代次、开发环境和测试结果仍可能需要它们，因此没有按 tag 年龄删除对象的任务。未来清理需要以保留的根及可达对象为依据。个人资料的恢复由 [Restic 备份](backup.md)负责。

## 本地验证

```sh
nix build --no-link .#oranc
nix develop --command python3 -m tests.integration.cache
```

集成使用临时 OCI registry 和合成密钥，执行与 CI 相同的发布筛选及直接 oranc 上传。场景包含复制受限内容的合成 bundle：保留该本地依赖，删除本次测试独有的公共输出，再从 registry 恢复并读取真实 NAR，验证内容和签名。真实 GHCR 权限、匿名访问与后续 CI 的缓存命中由托管环境验收。
