# 主机维护

主机在 `flake.nix` 的 `nixosConfigurations` 中明确注册。以下命令在仓库根目录运行，先选择要维护的机器：

```sh
host=laptop2
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

`--no-build` 只检查求值，不执行检查。跨领域修改或依赖升级的完整验收还包括领域检查、OCI 缓存集成和四组 VM 测试。`checks.e2e` 仅聚合 VM 结果。

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

对日志指出的冲突文件逐项保存、合并；确认处理完成后可重启对应服务。不要把整个用户配置目录删除后重试。

## 增加主机

1. 在 `hosts/<名称>/` 声明硬件、磁盘、启动方案、主机名、用户名、UID，以及该安装的系统和用户配置 `stateVersion`。
2. 导入需要的 profile，选择实际备份目标、频率和网络公告。`site.storage.persistRoot` 指定持久根；已有数据的位置变化需要单独迁移。
3. 配置该主机的 SOPS 密文与解密身份。`lib/credentials.nix` 提供 laptop 使用的字段绑定，主机传入目录、用户名与备份目标名称；可参考已有主机，不能复制其私钥或机器状态。
4. 在 `nixosConfigurations` 注册主机，构建系统并检查对应配置。需要托管验收和缓存时，再将名称加入验证工作流的 `matrix.host` 数组；当前 CI 面向 `x86_64-linux`，其他架构需要安排对应 runner 和验证入口。

具体机器的磁盘与恢复约定放在它自己的主机说明中。测试使用独立的合成 laptop 配置，不需要新增一台真实主机来运行通用检查。
