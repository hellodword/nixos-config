# laptop2 / NixOS

已有 laptop2 安装的系统配置：Sway、i3 和 Plasma 桌面，可独立组合的 DNS、代理与 Lockdown，以及三个独立的 Restic 备份仓库。

## 从哪里开始

| 任务 | 文档 |
| --- | --- |
| 修改 SSH、Wi-Fi、显示器、输入法和本机偏好 | [本机配置](docs/local-state.md) |
| 调整域名分流、代理节点或 Lockdown | [网络](docs/network.md) |
| 查看备份状态、控制范围和成本、恢复资料 | [备份](docs/backup.md) |
| 填写和管理本机加密凭据 | [主机凭据](docs/secrets.md) |
| 发送通知、配置通道和查看投递结果 | [本地通知](docs/notifications.md) |
| 使用桌面会话、浏览器和排查登录问题 | [桌面](docs/desktop.md) |
| 修改模块、脚本或测试 | [架构](docs/architecture.md)、[验证](docs/validation.md) |
| 理解组件选择与应用权限 | [选择与隔离边界](docs/choices.md) |
| 准备和使用 OCI 构建缓存 | [缓存](docs/cache.md) |

## 构建与检查

在源码 checkout 中运行：

```sh
nix build --no-link .#checks.x86_64-linux.unit .#checks.x86_64-linux.network .#checks.x86_64-linux.configuration
nix build --no-link .#nixosConfigurations.laptop2.config.system.build.toplevel
```

依赖由 `flake.lock` 固定；开发工具通过 `nix develop` 提供。构建使用公开配置和 SOPS 密文，个人数据在目标机激活时解密。

部署使用 `nixos-rebuild`。

## 日常升级与回退

在候选 checkout 更新依赖或配置，由独立的 `checks.x86_64-linux.e2e` 完成验收，再合并候选修改。检查入口与执行条件见[验证](docs/validation.md)。

```sh
nix flake update nixpkgs home-manager plasma-manager
nix build --no-link --no-update-lock-file .#checks.x86_64-linux.e2e
nix build --out-link result .#nixosConfigurations.laptop2.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#laptop2
```

涉及持久挂载、物理网络或 Lockdown 能力组合时，用 `nixos-rebuild boot` 后重启。升级成功后检查 `systemctl --failed`、`systemctl --user --failed`、`backup-status` 和日常应用。

回退前保存正在使用的应用数据，停止会话中会写配置的应用。可从启动菜单选择旧代次，也可以运行 `sudo nixos-rebuild switch --rollback`。系统回退选择旧程序与声明；应用数据库、钱包和本机偏好仍是当前持久数据，必要时从独立备份恢复到单独目录后审阅。Home Manager 冲突由 `journalctl -u home-manager-ubuntu.service -b` 给出，逐项保存对应文件，再重启该服务。
