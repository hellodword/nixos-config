# 备份与恢复

scaleway、r2、b2 三个现有 Restic 仓库各自读取源数据、加密上传并保存状态。一个目标故障时，其他目标独立执行。日常维护依据每个仓库的成功时间和恢复结果。

路径和仓库错峰由 `profiles/laptop/backup.nix` 选择，服务调度在 `modules/services/backup.nix`，运行逻辑在 `scripts/backup/`。每个仓库独立完成备份、检查、恢复通路验证与空间回收；仓库初始化与锁异常处理使用 Restic 原生命令。

## 路径范围与成本

路径相对 `site.storage.persistRoot`，laptop2 使用 `/persist`。在开发环境中可预览实际选择：

```sh
nix develop
sudo "$(command -v python3)" scripts/backup/runner.py plan \
  --policy /etc/backup/policy.json --source /persist --state /var/lib/site-backup-plan
```

清单含个人路径，应保存在本机受限目录。`bytes` 表示选择文件的逻辑大小；实际费用还受 Restic 去重、保留期、读取和对象 API 请求影响。

| 数据 | 策略 |
| --- | --- |
| machine-id、SSH 主机密钥、SOPS key、Secure Boot key | 存在时选中；SSH 仅选择 `ssh_host_*_key` 和 `.pub` |
| SSH/GPG、Git/WebDAV 导出 | 个人密钥、本机 SSH 覆盖与显式备份目录 |
| Firefox `default` / `origin` | cookie、登录密钥、会话、站点 LocalStorage / IndexedDB 及其元数据 |
| Bitwarden Desktop / CLI | 各自的 `data.json` 核心账户数据 |
| Anytype | 整个 `.config/anytype`，排除 Electron 缓存与 logs |
| KWallet 钱包与配置、显示器/输入法、Tailscale、Wi-Fi、Git 本机覆盖、代理配置 | 精确的持久状态 |
| ADB | `adbkey` 与 `adbkey.pub` |
| Downloads、大体积媒体、容器和 VM 镜像/卷 | 默认范围外；需要时加入明确的资料或应用导出路径 |
| 尚未安装的可选应用 | 在结果中记录缺失项 |

所有业务根缺失时都记录并跳过；已有但不可读的数据仍使作业失败。自动生成的 canary 用于验证备份及恢复通路。

`includePaths` 限定根内选中的文件，空列表选择整个根；`excludeNames` 匹配路径组件，`excludePaths` 相对各根。路径模式使用 `fnmatchcase`，其中 `*` 可跨 `/`。文件清单以 NUL 分隔传给 Restic，特殊字符按文件名原样处理。开发工作目录和 `Documents` 的持久化由系统管理，备份选择集中在上述资料与应用状态。

Restic 直接读取持久文件系统中的选定文件，符号链接保存为链接，不遍历其目标。Plasma 单文件链接的真实数据位于这些已选持久路径。遇到跨文件系统的目录时报告范围问题；读取期间变化或不可读文件会使备份记录失败，检查结果后可重跑。

Firefox 在线直接备份，SQLite 的 WAL 随库文件选择。会话文件包含会话 cookie，也带有标签页状态。站点的 LocalStorage / IndexedDB 可保存登录凭据；Cache API、浏览器缓存和 `permanent/chrome` 内部数据不在选择范围。在线文件副本不保证应用级事务一致性。

Bitwarden 的 `data.json` 同时承载加密 vault 和解密它所需的账户元数据，也可能混有 token 与客户端偏好；按核心文件整体保存。恢复仍需要账户解锁材料，云端附件另由服务保存。Electron 的缓存、cookie 数据库和外围配置不进入此范围。

## 调度与保留

| 操作 | 默认安排 |
| --- | --- |
| backup | 上海时间每天 10:10～12:00、21:10～23:00，每仓库每窗口成功一次；支持电池供电 |
| check | 晚间窗口接电且本窗口备份成功后，每 7 天读取 1/12 数据分片；成功后推进分片 |
| restore-test | 同样在晚间接电时，每 7 天恢复最新匹配快照的 canary 并核对哈希 |
| maintenance | 同样在晚间接电时，每 30 天执行结构检查、`forget --prune` 和回收后的结构检查 |

系统时区为 `America/New_York`，备份日历与窗口判断均使用 `Asia/Shanghai`，不随美国夏令时变化。scaleway 在窗口开始时尝试，r2、b2 分别延后 5、10 分钟，之后每 15 分钟重试。11:00 开机可补做上午备份；13:00 开机只检查本地状态，等到晚间窗口才访问仓库。窗口结束时间不包含在允许启动的范围内。

每个仓库只有一个自动调度 timer。它先补足本窗口备份，再按成功记录执行到期的检查、canary 恢复和回收。每个维护阶段开始前重新检查时间窗口和供电；窗口已结束或转为电池供电时，后续阶段等下一次允许的触发。已开始的阶段可继续完成。自动回收复用本窗口备份和本轮已完成的检查；手动维护先做新备份，再检查、回收和复查。

每目标用不等待的本地锁串行，并遵守 Restic 仓库锁；已有任务运行时，本次触发记为跳过。失败与中断保留上次成功时间。缓存持久保存，通过主机和标签选择父快照。注销不影响后台作业，作业允许系统正常休眠；关机或重启时停止整个进程组，最多等待 30 秒。休眠后的网络错误或中断在下个允许窗口重试。

维护按当前主机和 `site:<hostname>` 标签选择快照，以 `host,tags` 分组，保留 7 daily / 5 weekly / 12 monthly / 75 yearly。各条件保留结果取并集；一年中的最后一份匹配快照可能长期保留。所需备份或检查失败时，本轮不进入清理。

`forget` 决定删除哪些快照，`prune` 回收整个仓库中没有快照引用的数据。无标签的已有快照仍引用的数据会保留，因此保留参数不等于仓库大小上限。重新打包、读取和对象 API 调用可能计费。调整策略前可用 runner 的 `retention-plan` 预览当前范围，输出保存在对应状态目录的 `last-command.log`。

## 查看状态和处理失败

```sh
backup-status
systemctl list-timers 'site-backup-*'
sudo systemctl start site-backup-r2-automatic
sudo systemctl start site-backup-r2-backup
sudo systemctl start site-backup-r2-check
sudo systemctl start site-backup-r2-restore-test
sudo systemctl start site-backup-r2-maintenance
```

`backup-status` 按当前仓库、源路径和数据策略核对成功记录，分别公开 `backup`、`check`、`canaryRestore` 和 `maintenance` 的年龄与 `fresh` / `stale` / `unknown` 状态，并显示当前阶段及最近的成功、失败、中断或跳过结果。`check` 还显示本次校验的分区及总分区数；一次分区校验或 canary 恢复不代表全部资料已验证。更换仓库、源路径或数据策略后，历史记录不再充当当前结果；仅调整调度时间不会改变数据范围标识。

各操作的通知投递结果与待发送状态单独列出。每仓库、每类操作仅持久保留最新待发送结果，由独立服务投递和重试；备份停止流程只写本地结果。配置与查看方式见[本地通知](notifications.md)。备份超过 36 小时、检查或 canary 恢复超过 14 天、回收超过 45 天，以及状态未知或不可读，都会在桌面提示。用成功记录衡量恢复点，而非 systemd 启动时间。

详细记录与最近 Restic 输出位于 root-only 的 `/var/lib/site-backup-<target>/`。`last-command.log` 按 4 MiB 轮转并保留一份旧日志；失败时先查看它和相应服务的 journal。Restic exit 3 表示有文件未读到，也按失败处理。`automatic` 入口遵守时间窗口；上面的手动操作入口可按需执行，维护仍要求接电。需跳过成功间隔时，在相同运行时凭据环境下使用 runner 的 `--force`；本地锁和自动窗口规则继续生效。

每次成功更新目标自己的状态记录；失败详情保存在受限日志中，下一次执行继续使用同一仓库与缓存。密码和访问凭据使用运行时文件。三个仓库仍共享本机源盘、网络和凭据所在设备，离线或 Lockdown 阻断期间应关注成功时间是否过期。

## 独立恢复演练

1. 从离线介质取得仓库 URL、Restic 密码、访问凭据和 SOPS/磁盘恢复资料。恢复引导所需凭据应有独立副本。
2. 选择一个提供商，用受限环境文件及密码文件连接，确认主机、快照时间、标签和范围。
3. 执行 `restic restore <snapshot-id> --target <empty-recovery-directory> --verify`，恢复到独立空目录。
4. 检查文件内容、权限和 SSH/GPG keyring；KWallet 钱包还需要原解锁密码。
5. 分别使用另外两个仓库演练，记录快照、范围、日期和耗时。canary 用于日常通路检查，完整资料恢复另行验证。

Tailscale 状态用于原设备停用后的身份恢复，新设备另行注册。防范恶意删除还需要提供商侧的独立账号、最小权限、离线凭据及经过 Restic 兼容验证的不可变保留；桶生命周期直接删除 packs 会破坏仓库。

参考：[文件选择](https://restic.readthedocs.io/en/stable/040_backup.html)、[仓库检查](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)、[保留与 prune](https://restic.readthedocs.io/en/stable/060_forget.html)。具体选项以锁定版本为准。
