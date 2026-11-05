# OCI 构建缓存

[oranc](https://github.com/linyinfeng/oranc) 将 OCI 仓库作为标准 Nix binary cache。源码由 `flake.lock` 锁定，使用项目的 nixpkgs 构建；更新命令为 `nix flake update oranc`。

## 消费缓存

```nix
site.cache = {
  enable = true;
  repository = "your-owner/your-repository";
  publicKey = "your-cache-1:REPLACE_WITH_VERIFIED_BASE64_PUBLIC_KEY=";
  # 私有仓库使用 root 所有、权限 0600 的运行时文件：
  # netrcFile = "/run/secrets/cache-netrc";
};
```

`oranc.service` 监听 `127.0.0.1:37515`，Nix 使用 `http://127.0.0.1:37515/ghcr.io/<owner>/<repository>`，并校验指定公钥的签名。服务使用动态用户、只读系统目录、独立临时目录和设备视图，限制能力、命名空间与内核管理接口。日志通过 `journalctl -u oranc` 查看。Nix 也可以从官方缓存获取产物或本地构建。

私有仓库的 netrc 内容形如 `machine 127.0.0.1 login USER password TOKEN`。凭据由本机 Nix 发送给本机代理，再用于仓库认证；文件路径可以声明，凭据内容保存在运行时密钥文件中。

## 签名并审阅公开闭包

使用 Nix 原生命令，显式选择准备发布的公开输出。签名私钥保存在仓库外的 0600 文件中；可信公钥通过独立渠道核对。下面示例只构建公开软件包：

```sh
nix develop
umask 077
cache_dir=$(mktemp -d /tmp/public-nix-cache.XXXXXX)
signing_key=/run/credentials/nixcache.secret
trusted_key=$(cat /run/credentials/independently-trusted-nixcache.public)
root=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.virtualbox)
nix path-info --recursive "$root"
nix key convert-secret-to-public < "$signing_key"
```

审阅闭包清单，并将输出公钥与 `trusted_key` 核对。完整系统闭包可能含个人密文和主机配置；发布范围由上面的明确输出决定。签名后验证导出的整个闭包：

```sh
nix copy --to "file://$cache_dir?secret-key=$signing_key&compression=xz&compression-level=1" "$root"
nix store verify --store "file://$cache_dir" --recursive --sigs-needed 1 \
  --option trusted-public-keys "$trusted_key" --option extra-trusted-public-keys '' "$root"
```

## 发布到 OCI 仓库

在另一个终端运行前台代理，完成发布后用 Ctrl+C 关闭：

```sh
nix develop --command oranc server --listen 127.0.0.1:37516
```

回到持有上述变量的终端。Docker registry 凭据文件包含 `auths.ghcr.io.auth`，值是 `USER:TOKEN` 的 Base64 编码，文件权限为 0600。将下面的 owner 和 repository 换成已审阅的目的地：

```sh
export AWS_ACCESS_KEY_ID=$(jq -r '.auths["ghcr.io"].auth' /run/credentials/registry-auth.json)
export AWS_SECRET_ACCESS_KEY=_
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
nix copy --from "file://$cache_dir" \
  --to 's3://your-repository?endpoint=http://127.0.0.1:37516/ghcr.io/your-owner' "$root"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_EC2_METADATA_DISABLED
```

oranc 将标准 Nix cache 对象保存到该 OCI repository。私有缓存读取时，使用配置为该本机代理提供认证的 netrc；公开缓存可直接执行：

```sh
nix store verify --store http://127.0.0.1:37516/ghcr.io/your-owner/your-repository \
  --recursive --sigs-needed 1 --option trusted-public-keys "$trusted_key" \
  --option extra-trusted-public-keys '' "$root"
```

验证后释放本次 `cache_dir`，保留需要的发布记录与独立公钥。远端历史对象的保留由仓库管理。

## 本地验证

```sh
nix develop --command python3 -m tests.integration.cache
```

测试启动临时 OCI registry 和 oranc，用合成密钥签名、发布并恢复一个含依赖的闭包，再读取实际 NAR 校验内容与签名。真实 GHCR 身份权限在发布环境验证。个人资料恢复使用 [Restic 备份](backup.md)。
