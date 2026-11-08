# NixOS configuration

以 laptop profile 组合桌面、网络、备份和开发环境的 NixOS 配置。支持 Sway、i3 和 Plasma，使用声明式系统配置，同时保留应用需要自行修改的持久状态。

目前注册的主机是 [laptop2](hosts/laptop2/README.md)。主机目录记录具体机器的硬件、身份和策略；`profiles/laptop/` 维护共同选择，`modules/` 提供能力。

| 要做什么 | 从这里开始 |
| --- | --- |
| 构建、升级、切换、回退或增加主机 | [主机维护](docs/maintenance.md) |
| 修改 SSH、Wi-Fi、显示器、输入法和本机偏好 | [本机配置](docs/local-state.md) |
| 调整分流、代理节点或 Lockdown | [网络](docs/network.md) |
| 查看备份状态、控制成本、恢复资料 | [备份](docs/backup.md) |
| 管理加密凭据与 SSH/GPG 身份 | [凭据](docs/secrets.md) |
| 使用桌面和排查登录、钱包问题 | [桌面](docs/desktop.md) |
| 配置通知与排查投递 | [通知](docs/notifications.md) |
| 理解模块、脚本和状态之间的关系 | [架构](docs/architecture.md) |
| 选择并运行检查 | [验证](docs/validation.md) |
| 配置 GitHub 自动更新与验收 | [CI](docs/ci.md) |
| 配置构建缓存、签名与发布 | [缓存](docs/cache.md) |

在 checkout 中选择主机并构建：

```sh
host=laptop2
nix build --no-link ".#nixosConfigurations.${host}.config.system.build.toplevel"
nix build --no-link .#checks.x86_64-linux.identity
```

依赖由 `flake.lock` 固定，开发工具通过 `nix develop` 提供。Home Manager 随 NixOS 系统一起构建和激活。构建读取公开配置与 SOPS 密文，凭据在目标机激活时解密。

已有安装的迁移恢复材料保存在[归档](docs/archive/laptop2-migration.md)，日常维护使用现行指南。
