# 主机维护

主机在 `flake.nix` 的 `nixosConfigurations` 中明确注册。以下命令在仓库根目录运行，先选择要维护的机器：

```sh
host=laptop2  # 换成要维护的主机
nix eval --json .#nixosConfigurations --apply builtins.attrNames
```

## 构建与切换

```sh
nix build --out-link result ".#nixosConfigurations.${host}.config.system.build.toplevel"
sudo nixos-rebuild switch --flake ".#${host}"
```

构建包含系统软件、服务和所有 Home Manager 用户的激活配置。Home Manager 使用 NixOS 模块，由系统负责激活。凭据绑定和填写方法见[凭据指南](secrets.md)；构建本身不解密 SOPS 文件。

涉及持久挂载、物理网络、启动配置或 Lockdown 能力组合时，安排重启应用：

```sh
sudo nixos-rebuild boot --flake ".#${host}"
```

重启后检查 `systemctl --failed`、`systemctl --user --failed`、`backup-status`，并确认常用应用和网络正常。构建缓存的持久设置见[缓存](cache.md)。

## 更新与验证

日常依赖更新可由 [GitHub Actions](ci.md)完成。本地更新时，通过 Nix 写入锁文件，然后按改动范围选择[检查](validation.md)：

```sh
nix flake update nixpkgs home-manager plasma-manager
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
nix flake check --no-build
```

`--no-build` 只检查求值，不执行检查。依赖升级或跨领域修改按[完整验收流程](validation.md#完整验收与计时)验证后再部署。

自动更新的输入清单由[更新工作流](../.github/workflows/update.yml)维护。单独更新一个 input 使用 `nix flake update <名称>`，例如输入法主题：

```sh
nix flake update catppuccin-fcitx5
```

网络规则、缓存代理和可选 VM 客户端的升级要求分别见[网络](network.md#规则来源与更新)、[缓存](cache.md#项目-oci-缓存)和[VM 工具说明](../tools/vm-test-mcp/README.md)。

## 回退与激活故障

可从启动菜单选择旧代次，或在适合立即切换时运行：

```sh
sudo nixos-rebuild switch --rollback
```

系统回退选择旧程序和声明，应用数据库、钱包与本机偏好仍使用当前持久数据。需要恢复数据时，先恢复到单独目录并审阅，见[备份](backup.md)。

在受影响用户的会话中查看 Home Manager 激活记录：

```sh
login_user=$(id -un)
systemctl status "home-manager-${login_user}.service"
journalctl -b -u "home-manager-${login_user}.service"
```

对日志指出的冲突文件，先停止所属应用，用 `findmnt -T <路径>` 确认是否涉及持久挂载，再将文件保存到选定的持久目录并逐项合并。挂载点按其持久化声明处理；完成后重启对应服务。不要把整个用户配置目录删除后重试。

## Docker 维护

[容器配置](../modules/services/containers.nix)启用每周自动 prune，清理停止的容器、未使用网络、悬空镜像和构建缓存；卷不在默认清理范围。启用通知服务时，清理会保留带有 `org.nixos-config.service` 标签的受管资源。观察空间与清理记录：

```sh
docker system df
systemctl list-timers docker-prune.timer
journalctl -u docker-prune.service
```

新建容器默认使用 `local` 日志驱动，按大小轮转，通过 `docker logs <容器名>` 查看。`live-restore` 在兼容的 Docker daemon 重启期间尽量保持普通容器运行；系统关机或明确停止应用服务仍会结束容器。容器联网见[网络指南](network.md#docker-与-compose)。

## 增加主机

1. 在 `hosts/<名称>/` 声明硬件、磁盘、启动方案、主机名、用户名、UID，以及该安装的系统和用户配置 `stateVersion`。
2. 导入需要的 profile，选择实际备份目标、频率和网络公告。`site.storage.persistRoot` 指定持久根；已有数据的位置变化需要单独迁移。
3. 配置该主机的 SOPS 密文与解密身份。`lib/credentials.nix` 提供 laptop 使用的字段绑定，主机传入目录、用户名与备份目标名称；可参考已有主机，不能复制其私钥或机器状态。
4. 在 `nixosConfigurations` 注册主机，构建系统并检查对应配置。需要托管验收和缓存时，再将名称加入验证工作流的 `matrix.host` 数组；当前 CI 面向 `x86_64-linux`，其他架构需要安排对应 runner 和验证入口。

具体机器的磁盘与恢复约定放在它自己的主机说明中。测试使用独立的合成 laptop 配置，不需要新增一台真实主机来运行通用检查。
