# 构建缓存

## 配置如何生效

本项目的 NixOS 主机和 CI 自动配置构建缓存，其他开发环境需要[安装客户端配置](#开发容器及其他-nix-客户端)。这些设置持久生效，构建其他 flake 项目时同样使用，无需在每次运行 Nix 时添加参数。

添加或移除公共缓存时，修改 [flake.nix](../flake.nix) 的 `nixConfig`；更换项目缓存仓库或签名身份时，修改 [cache-identity.json](../nix/cache-identity.json)。代理地址和端口在 [cache-config.nix](../nix/cache-config.nix) 中设置。修改后，NixOS 主机重新部署配置，其他客户端重新执行安装命令。

缓存需要包含构建所请求的精确 store path。自定义源码或构建参数可能产生公共缓存没有的路径，由项目缓存补充；刚初始化的项目缓存还需要经过构建和发布才有软件产物。

## 项目 OCI 缓存

[oranc](https://github.com/linyinfeng/oranc) 将声明的 GHCR package 提供为标准 Nix binary cache。它与自身的构建依赖一起独立锁定，不参与每日更新。单独升级使用 `nix flake update oranc`，验证方式见[本地验证](#本地验证)。

package 的创建、Public 和 Actions Write 设置见 [CI 首次启用](ci.md#首次启用)。CI 在使用项目缓存前直接 GET `nix-cache-info`；不要用 `nix store info` 探测尚未初始化的缓存，当前固定版本的 oranc 在该路径上可能尝试创建索引，导致匿名请求出现 500。初始化只写入索引，不发布软件闭包，也不修改 package 的可见性。

## NixOS 主机与容器

主机通过 `site.cache` 指定项目仓库、公钥、监听地址和端口。默认只监听本机；需要与 Docker 容器共用时，选择容器可达的宿主地址，并在依赖网桥时安排服务在 Docker 之后启动。[laptop2 的主机配置](../hosts/laptop2/default.nix)采用统一声明的网桥地址，可作为此类配置的实例。

切换配置后，`nixos-rebuild`、`nix build` 和 `nix develop` 自动使用公共缓存与项目缓存，并验证签名。首次切换的构建使用旧代次的 Nix 配置。公共 GHCR 包可匿名读取，消费端只需公钥，无需签名私钥或 registry token。容器访问由[私网访问策略](network.md#私网开发访问与公网入站)管理。

在采用统一声明的主机上，可从仓库根目录检查已初始化的缓存：

```sh
systemctl status oranc
journalctl -u oranc
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
cache_url=$(nix eval --raw --file nix/cache-config.nix local.uri)
nix store info --store "$cache_url"
```

使用其他地址的主机需相应替换 `cache_url`。禁用项目代理时公共缓存继续可用。私有仓库可配置 `site.cache.netrcFile`，指向 root 所有的 0600 运行时文件；`machine` 与客户端使用的代理地址一致。凭据由 Nix 发送给代理用于上游认证，内容不进入 Nix store。

## 开发容器及其他 Nix 客户端

宿主提供可达的 oranc 代理后，在开发容器的源码 checkout 中查看并安装客户端配置：

```sh
bash scripts/nix-cache.sh print
bash scripts/nix-cache.sh install
nix config show | rg 'substituters|trusted-public-keys|require-sigs'
nix develop
```

`install` 将配置写入 `${XDG_CONFIG_HOME:-$HOME/.config}/nix/nixos-config-cache.conf`，并在同目录 `nix.conf` 中加入相对 `include`，保留原有设置。再次运行会更新托管片段，不重复添加 include。之后直接使用原生 Nix 命令。重建容器或更新缓存声明后重新执行安装命令，也可将它接入容器自身已有的初始化流程。

无法访问宿主代理时，用 `print --public-only` 查看、`install --public-only` 安装公共缓存。脚本不需要先进入开发 shell；其他参数见 `bash scripts/nix-cache.sh --help`。

多用户 Nix 的下载和信任由 daemon 决定，仅修改普通用户配置不能授权新的缓存公钥。在非 NixOS 的 daemon 安装中，由管理员执行：

```sh
sudo bash scripts/nix-cache.sh install --system
sudo systemctl restart nix-daemon.service
```

系统模式写入 `${NIX_CONF_DIR:-/etc/nix}`，由当前平台的服务管理器重启运行中的 daemon。NixOS 主机通过声明式配置和 `nixos-rebuild` 应用。若设置了 `NIX_USER_CONF_FILES`，需确认它包含安装目标的 `nix.conf`；`NIX_CONFIG` 和命令行遵循 Nix 自身的优先级。

直接打开 flake 时，Nix 可能另外要求确认仓库内的缓存设置，审阅 URL 和公钥后再决定是否接受。忽略这份 flake 设置不会移除已安装的持久设置，可用 `nix config show` 核对。配置层次与 daemon 行为见 [Nix 配置文档](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html)。

## 发布范围

[cache-policy.nix](../nix/cache-policy.nix) 定义构建根与再分发限制。[发布脚本](../.github/ci/cache.py)沿构建依赖图选取已经实现的 derivation 输出，再收集这些产物的运行时引用。求值直接写入 store 的文件也会随运行时引用纳入。部分构建或 VM 失败时，其余已完成的可再分发路径仍可发布，供下轮使用。发布时机见 [CI 执行顺序](ci.md#主机与执行顺序)。

默认开发环境及其依赖随 CI 发布到项目缓存。配置缓存后，本地和 CI 的 `nix develop` 可复用其中的工具，包括 VM 提交客户端。缓存匹配相同的 store path，flake 求值仍在当前机器进行。

公开范围包括可再分发的自定义包、配置产物及成功的 Nix VM 测试结果。输入相同的检查可以恢复已有成功结果，如何区分复用与本轮执行见[验证指南](validation.md#完整验收与计时)。

软件许可证的 `redistributable` 元数据用于筛选直接软件包。有再分发限制的软件、下载源及复制这些内容的 bundle 不发布；普通系统包装脚本、符号链接和元数据可以保留对它们的引用。`unfreeRedistributable` 与禁止再分发的许可分别处理。

新增软件或将软件复制进 bundle 时，应核对许可证及 `cache-policy.nix` 中的排除范围；仅靠 Nix store 引用无法识别复制进去的内容及其再分发权。发布只上传筛选后的路径，避免自动展开依赖而带入受限内容。

CI 先从原始来源构建被排除的软件及容器，再请求 E2E 结果，保证恢复测试结果时所需的受限依赖已经存在。消费缓存的主机仍自行取得这些应用；部分引用它们的上层产物可能由 Nix 在本地组装，其余可发布依赖继续命中缓存。公开缓存不是完整主机闭包的独立离线副本。

## 签名、重试与历史对象

产物发布使用运行时的 `NIX_CACHE_SIGNING_KEY`、GITHUB_TOKEN 和 `oranc push`。日常 CI 在首次写入前将私钥推导出的公钥与仓库声明核对。手动初始化入口只写不含产物签名的索引，无需私钥。私钥不保存在仓库或 Nix 构建环境中；密钥生成与交接见下文[签名密钥](#签名密钥)，仓库权限见 [CI 启用步骤](ci.md#首次启用)。

CI 根据本地已有的公共缓存签名、项目签名及本轮上传记录去重，再向公共缓存和项目缓存查询剩余路径的元数据。Nix 核对同一路径的 NAR 哈希、大小和引用后导入签名，据此跳过远端已有的产物。公共缓存采用仓库声明和 Nix 内置的默认缓存配置。

缓存查询失败时，CI 记录端点及错误，继续发布尚未确认有缓存的路径。查询只读取元数据；实际上传按未压缩 NAR 大小分组，先逐个上传大产物，再并行上传其余产物，以控制内存峰值。参数集中在[发布脚本](../.github/ci/cache.py)。

发布使用有限重试，每组成功后更新本轮上传记录。发布失败会使 CI 失败；下一次运行通过远端项目签名识别已完成的上传，继续处理剩余路径。发布数量、缓存命中、待上传体积及查询和上传耗时见 [CI 诊断](ci.md#资源和故障记录)。

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

最后输出的是公钥，将其填写到 `nix/cache-identity.json` 的 `publicKey`。私钥文件的完整内容填写到 [GitHub 仓库 secret](ci.md#首次启用) `NIX_CACHE_SIGNING_KEY`；也可以在对应仓库的 checkout 中通过 CLI 上传：

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

集成使用临时 registry 和合成密钥，覆盖范围见[验证指南](validation.md#完整验收与计时)。首次启用和权限变更还需通过真实 Actions 运行确认 GHCR 匿名访问、发布权限及后续缓存命中。
