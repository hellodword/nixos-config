# 构建缓存

## 声明与配置来源

[flake.nix](../flake.nix) 的 `nixConfig` 声明 [Nix Community](https://nix-community.org/cache/) 与 [Numtide](https://github.com/numtide/llm-agents.nix#binary-cache) 的 URL 和签名公钥，以 `extra-` 设置保留 Nix 的官方缓存。Nix 在 flake 求值前读取这些设置，因此这里使用字面量列表。

[nix/cache-config.nix](../nix/cache-config.nix) 读取这份声明和 [nix/cache-identity.json](../nix/cache-identity.json) 中的项目仓库、签名公钥，生成 NixOS、开发容器和 CI 使用的配置。宿主代理地址与端口也在该汇总层声明。公共缓存更新时修改 `flake.nix`；项目签名身份更新时修改 `cache-identity.json`。

缓存只能提供精确 store path 对应的产物。公共缓存可覆盖部分官方缓存缺失的依赖，但自定义源码、构建参数或修改后的 derivation 需要项目自身发布。项目缓存初始化后仍可能没有所需产物，首次构建会填充它；不同包的并行构建时间不能简单相加估算节省量。

## 项目 OCI 缓存

[oranc](https://github.com/linyinfeng/oranc) 将 `ghcr.io/hellodword/nixos-config` 作为标准 Nix binary cache。上游由 `flake.lock` 固定，`packages.x86_64-linux.oranc` 使用项目的 nixpkgs 构建；主机服务、开发 shell 和 CI 复用该包。oranc 不参与每日更新，单独升级使用 `nix flake update oranc`。

package 的创建、Public 和 Actions Write 设置见 [CI 首次启用](ci.md#首次启用)。CI 在使用项目缓存前直接 GET `nix-cache-info`；不要用 `nix store info` 探测尚未初始化的缓存，当前固定版本的 oranc 在该路径上可能尝试创建索引，导致匿名请求出现 500。初始化只写入索引，不发布软件闭包，也不修改 package 的可见性。

## NixOS 主机与容器

主机通过 `site.cache` 启用 OCI 缓存并提供缓存身份。[laptop2](../hosts/laptop2/default.nix) 的配置让 `oranc.service` 监听 **`172.17.0.1:37515`**。Docker 默认网桥固定使用 `172.17.0.1/16`，服务排在 Docker 启动之后；地址暂未就绪时由服务的失败重启策略恢复。Nix 的持久配置包含公共缓存及 `http://172.17.0.1:37515/ghcr.io/hellodword/nixos-config`，保留官方缓存并要求签名。

切换到该配置后，`nixos-rebuild`、`nix build` 和 `nix develop` 自动使用缓存，无需每次增加参数。首次切换的构建仍使用旧代次的 Nix 配置。公共 GHCR 包可匿名读取，消费缓存的主机无需配置 registry token。服务使用动态用户、只读系统目录、独立临时目录和设备视图，并限制能力、命名空间与内核管理接口。宿主、默认 bridge 和普通 Compose bridge 共用这一个代理，容器访问沿用现有 `localAccess` 策略；没有为缓存新增公网端口放行。

```sh
systemctl status oranc
journalctl -u oranc
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix store info --store http://172.17.0.1:37515/ghcr.io/hellodword/nixos-config
```

其他主机可通过 `site.cache` 指定仓库、公钥、`listenAddress` 和端口；监听默认值是 `127.0.0.1`。禁用项目代理时仍保留公共缓存。私有仓库可配置 `netrcFile` 指向 root 所有的 0600 运行时文件，`machine` 应与客户端使用的代理地址一致；凭据由 Nix 发送给代理，再用于上游认证。凭据内容不进入 Nix store。

## 开发容器及其他 Nix 客户端

在采用上述网桥配置的宿主上，开发容器直接访问 `172.17.0.1`。容器只安装客户端设置，服务由宿主 systemd 管理。在源码 checkout 中执行一次：

```sh
bash scripts/nix-cache.sh print
bash scripts/nix-cache.sh install
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix develop
```

`install` 将配置写入 `${XDG_CONFIG_HOME:-$HOME/.config}/nix/nixos-config-cache.conf`，并在同目录 `nix.conf` 中加入相对 `include`，保留原有设置。再次运行会更新托管片段，不重复添加 include。之后直接使用原生 Nix 命令。重建容器或更新缓存声明后重新执行安装命令，也可将它接入容器自身已有的初始化流程。

其他机器若无法访问这台宿主，可用 `print --public-only` 查看、`install --public-only` 安装公共缓存。`print --ci` 输出使用回环代理的 CI 配置。脚本只依赖 Nix、Bash 和基本命令行工具，不要求先构建开发 shell。成功返回 0，用法错误返回 2，配置生成或文件写入失败返回非零；配置输出走 stdout，安装说明走 stderr。

多用户 Nix 的下载和信任由 daemon 决定，仅修改普通用户配置不能授权新的缓存公钥。在非 NixOS 的 daemon 安装中，由管理员执行：

```sh
sudo bash scripts/nix-cache.sh install --system
sudo systemctl restart nix-daemon.service
```

系统模式写入 `${NIX_CONF_DIR:-/etc/nix}`，由当前平台的服务管理器重启运行中的 daemon。NixOS 主机通过上述声明式配置和 `nixos-rebuild` 应用。脚本不增加 `trusted-users`，不关闭签名验证，也不全局自动接受任意 flake 配置。若设置了 `NIX_USER_CONF_FILES`，需确认它包含安装目标的 `nix.conf`；`NIX_CONFIG` 和命令行仍遵循 Nix 自身的优先级。

直接打开 flake 时，Nix 可能要求首次确认仓库内的缓存设置。审阅 URL 和公钥后作出信任决定即可；持久配置已经为日常命令提供相同公共缓存，无需每次附加参数。配置层次与 daemon 行为见 [Nix 配置文档](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html)。

## 发布范围

[GitHub 工作流](ci.md)在依赖构建结束和验证收尾时各发布一次。构建或 VM 失败时，已经完成的可再分发路径仍可供下轮使用；失败的测试没有结果可发布。[nix/cache-policy.nix](../nix/cache-policy.nix) 定义所选主机系统、开发 shell、oranc 与检查输出的构建根；[.github/ci/cache.py](../.github/ci/cache.py) 从这些 derivation 中选取实际已存在的运行依赖、构建依赖和源码路径，排除 `.drv` 与受限内容。

公开范围包括可再分发的自定义包、配置产物及成功的 Nix VM 测试结果。输入和测试实现均未改变时，Nix 可以直接恢复已通过的测试输出；哈希变化的检查重新执行。oranc 跳过已有官方签名或本缓存签名的路径，使用 `--no-closure` 发布已筛选的清单，避免再次展开出受限依赖。发布不会向本地 Nix 数据库添加签名，因此本轮成功发布的清单保存在 CI 状态目录，第二次只提交新增路径。

软件许可证的 `redistributable` 元数据用于筛选所选主机、该主机全部 Home Manager 用户、测试配置及 VS Code 扩展中的直接软件包。VS Code、VS Code Server、Chrome、Remote Containers 扩展、p7zip 的受限输出与下载源不发布。应用测试的开发容器复制了 VS Code Server，其镜像及依赖链上携带受限内容的中间产物也被排除。普通系统包装脚本、符号链接和元数据可以保留对这些路径的引用。

新增软件或将软件复制进其他 bundle 时，需要同步这份清单并审阅许可证；单纯读取 Nix store 引用无法判定文件的再分发权。`unfreeRedistributable` 与禁止再分发的许可分别处理，不会一概排除所有 unfree 软件。

CI 先从原始来源构建被排除的软件及容器，再请求 E2E 结果，保证恢复测试结果时所需的受限依赖已经存在。消费缓存的主机仍自行取得这些应用；部分引用它们的上层产物可能由 Nix 在本地组装，其余可发布依赖继续命中缓存。公开缓存不是完整主机闭包的独立离线副本。

## 签名、重试与历史对象

产物发布使用运行时的 `NIX_CACHE_SIGNING_KEY`、GITHUB_TOKEN 和 `oranc push`。日常 CI 在首次写入前将私钥推导出的公钥与仓库声明核对。手动初始化入口只写不含产物签名的索引，无需私钥。私钥不保存在仓库或 Nix 构建环境中；密钥生成与交接见下文[签名密钥](#签名密钥)，仓库权限见 [CI 启用步骤](ci.md#首次启用)。

发布并发为 1，zstd level 为 3，`max-retry=3` 使用锁定版本的内置重试。NAR 上传成功后才写入对应 narinfo，整批成功后才更新本轮发布清单。发布失败保留非零结果，不将未完成路径记为成功；第二次发布或后续运行可重试。CI 与自动合并仍要求构建、测试和发布全部成功。

历史 GHCR 对象持续保留。narinfo 引用对应 NAR，旧系统代次、开发环境和测试结果仍可能需要它们，因此没有按 tag 年龄删除对象的任务。未来清理需要以保留的根及可达对象为依据。个人资料的恢复由 [Restic 备份](backup.md)负责。

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

最后输出的是公钥，将其填写到 `nix/cache-identity.json` 的 `publicKey`；私钥文件的完整内容上传为仓库 secret：

```sh
signing_key="${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config/cache/nixos-config-1.secret"
gh secret set NIX_CACHE_SIGNING_KEY < "$signing_key"
```

在正确的仓库 checkout 中执行，并先核对推导出的公钥。备份仓库外的私钥文件以便迁移和恢复。正式轮换时采用新的名称与文件名（例如 `nixos-config-2`），协调更新 CI 私钥和消费者信任，并安排旧缓存的签名过渡。

## 本地验证

```sh
nix build --no-link .#oranc
nix develop --command python3 -m tests.integration.cache
```

集成使用临时 OCI registry 和合成密钥，执行与 CI 相同的发布筛选及直接 oranc 上传。场景让一个独立构建失败，发布其余已完成产物，再完成测试并只发布新增结果；复制受限内容的 bundle 始终保留在本地。随后删除本次测试独有的公共输出，通过安装器生成的持久配置运行普通 Nix 构建，从 registry 恢复真实 NAR，验证内容和签名。网络 VM 使用生产 oranc 服务，让宿主、默认 Docker bridge 与 Compose bridge 下载同一份真实 NAR，并验证网络与服务恢复后的访问。真实 GHCR 权限、匿名访问与后续 CI 的缓存命中由托管环境验收。
