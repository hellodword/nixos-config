# 备份与恢复

每个备份目标使用独立的 Restic 仓库，分别读取源数据、加密上传并保存状态。一个目标故障时，其他目标独立执行。日常维护依据每个仓库的成功时间和恢复结果。

调整备份资料范围时修改 [laptop 的备份策略](../profiles/laptop/backup.nix)，目标仓库与频率在各[主机配置](../hosts)中选择。初始化和独立灾难恢复使用 Restic 原生命令。

## 路径范围与成本

路径相对 `site.storage.persistRoot`。下面以默认持久根 `/persist` 为例，在目标主机的开发环境中预览实际选择；其他位置需相应替换：

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

| 操作 | 共享默认安排 |
| --- | --- |
| backup | 上海时间每天 10:10～12:00、21:10～23:00，每仓库每窗口成功一次；支持电池供电 |
| check | 晚间窗口接电且本窗口备份成功后，每 7 天读取 1/12 数据分片；成功后推进分片 |
| restore-test | 同样在晚间接电时，每 7 天恢复最新匹配快照的 canary 并核对哈希 |
| maintenance | 同样在晚间接电时，每 30 天执行结构检查、`forget --prune` 和回收后的结构检查 |

备份日历与窗口判断均使用 `Asia/Shanghai`，独立于主机时区。11:00 开机可补做上午备份；13:00 开机只检查本地状态，等到晚间窗口才访问仓库。窗口结束时间不包含在允许启动的范围内。

默认情况下，自动备份失败后至少间隔 15 分钟重试，成功后停止本窗口的尝试；同一重任务失败后至少间隔 24 小时重试。各目标可以设置窗口偏移、尝试次数和重任务间隔，具体取值由主机决定，现有实例见 [laptop2 的备份配置](../hosts/laptop2/README.md)。

重任务指 `check`、`restore-test`、`maintenance`。每目标只有一个自动 timer，每 15 分钟在窗口内评估本地记录；达到最小间隔后，由下一次 timer 触发执行。先补足本窗口备份，再从允许执行的到期重任务中选择最久未尝试的任务；从未尝试的优先，同一时间按检查、canary、回收排序。某项检查失败会延后该项的下一次尝试，正常备份仍按自己的窗口执行。各项成功间隔从完成时间计，自动重任务之间的间隔从开始时间计，失败重试从结束时间计；断电时没有结束记录则以最后开始时间计算。记录按 target 名称持久保存，重启、调整备份路径和一次“跳过”都沿用这些时钟。

每次备份采用当时的文件清单，由 Restic 处理新增、变化和已有内容并生成快照。成功记录表示过去一次执行的结果；新增备份路径在下一次实际备份时纳入。当前窗口已经成功的备份继续计入该窗口，需要立即备份新路径时可手动启动 `backup`。

每个维护阶段开始前重新检查窗口和供电；窗口结束或转为电池供电时，后续阶段等下一次允许的触发。已开始的阶段可继续完成。自动回收复用本窗口备份和本轮已完成的检查；手动维护先做新备份，再检查、回收和复查。

`site.backup` 下的共享默认值可由 `targets.<名称>` 覆盖：

| 配置 | 含义 |
| --- | --- |
| `schedule.timeZone`、`windows`、`retryMinutes` | 自动窗口、时区及窗口内评估间隔 |
| `schedule.offsetMinutes` | 单仓库相对窗口开始的偏移；共享默认来自 `site.backup.schedule.offsets` |
| `automatic.enable` | 启用该仓库的自动 timer 和自动入口 |
| `automatic.backupAttemptsPerWindow` | 自动入口允许的备份尝试数；`null` 表示不限次数，仍受重试间隔约束 |
| `automatic.heavySpacingSeconds` | 各重任务之间的最小开始间隔 |
| `automatic.retryIntervalSeconds.<操作>` | 对应操作失败或中断后的自动重试间隔 |
| `minimumIntervalSeconds.<操作>` | 距上次成功的最小间隔，操作为 `backup`、`check`、`restore-test`、`maintenance` |
| `health.<操作>` | 健康状态的超期阈值，与执行频率分别设置 |
| `recoverStaleLocks` | 明确只有本机使用的仓库，允许受控遗留锁恢复 |

例如只调整一个仓库的检查频率与健康阈值：

```nix
site.backup.targets.b2 = {
  minimumIntervalSeconds.check = 14 * 86400;
  health.check = 28 * 86400;
};
```

生效策略可查看 `/etc/backup/targets/<名称>.json`；共享的 `/etc/backup/policy.json` 描述数据范围。调度使用当前策略和该目标已有的成功、尝试记录计算下次执行时间。自动限制只影响 `automatic` 入口；手动服务可以额外执行，仍遵守成功间隔和本地互斥。手动尝试会更新记录，后续自动调度据此计算间隔；手动备份也计入所在窗口的尝试数。

每目标用不等待的本地锁串行，并遵守 Restic 仓库锁；已有任务运行时，本次触发记为跳过。失败与中断保留上次成功时间。备份和 canary 使用持久缓存，通过主机和标签选择父快照。每次检查使用 Restic 默认的新建临时缓存：索引、快照及元数据 pack 从远端读取，同一轮检查复用已读数据，结束后释放临时缓存。分片仅在成功后推进。调整分片总数后，下次到期检查从新划分的第一片开始。

维护按当前主机和 `site:<hostname>` 标签选择快照，以 `host,tags` 分组，保留 7 daily / 5 weekly / 12 monthly / 75 yearly。各条件保留结果取并集；一年中的最后一份匹配快照可能长期保留。所需备份或检查失败时，本轮不进入清理。

`forget` 决定删除哪些快照，`prune` 回收整个仓库中没有快照引用的数据。无标签的已有快照仍引用的数据会保留，因此保留参数不等于仓库大小上限。重新打包、读取和对象 API 调用可能计费。调整策略前可用 runner 的 `retention-plan` 预览当前范围，输出保存在对应状态目录的 `last-command.log`。

## 请求与下载预算

仓库策略限制操作的启动频率。单次操作的请求数、下载量、分页、重试和锁续期仍由数据规模与 Restic 行为决定；错误统一按对应操作的失败间隔处理。错误摘要可供判断账户额度、权限和连接问题，调度器不解析供应商错误码或额度重置日历。

账户额度、存储类别和实际仓库规模按主机记录，见 [laptop2 的预算记录](../hosts/laptop2/README.md#备份账户与预算)。更换账户后需重新核对控制台，不能直接沿用另一台机器的额度。

B2 S3 的 GET/HEAD 属 B、LIST 和桶位置查询属 C；R2 的 LIST/PUT 属 A、GET/HEAD 属 B，DELETE 免费。以下是使用 Restic 0.19.1 对合成 S3 仓库的一次请求观测：500 个目录、两个快照、25 个变更文件，无分页、重试和分段上传。它用于判断操作量级，不能当成实际仓库的固定单价。[B2 分类](https://www.backblaze.com/cloud-storage/transaction-pricing)、[R2 分类](https://developers.cloudflare.com/r2/pricing/#class-a-operations)。

| 操作 | B2 B / C | R2 A / B |
| --- | --- | --- |
| 普通 unlock，无遗留锁 | 3 / 3 | 2 / 4 |
| snapshots，热缓存 | 3 / 5 | 5 / 4 |
| 无变化备份，热 / 冷缓存 | 3 / 6；9 / 6 | 7 / 4；7 / 10 |
| 25 个文件变化的备份，热缓存 | 3 / 6 | 10 / 4 |
| 1/12 检查，新建临时缓存 | 10 / 7 | 7 / 11 |
| 1/12 检查，禁用缓存 | 537 / 7 | 7 / 538 |
| 结构检查，新建临时缓存 | 9 / 7 | 7 / 10 |
| canary 恢复，热 / 冷缓存 | 4 / 6；10 / 6 | 6 / 5；6 / 11 |
| 保留期预览 | 3 / 5 | 5 / 4 |
| forget + prune，保留一份合成快照 | 4 / 8 | 12 / 5 |
| 本地状态、通知重试 | 0 / 0 | 0 / 0 |

完整 `maintenance` 还包含所需备份、回收前后检查。prune 的重打包规模、恢复范围和缓存状态决定读取量，小型演练结果不能外推完整恢复费用。请求免费也仍可能受到服务速率限制；R2 和 Scaleway 的公开政策没有这里 B2 账户的 2,500 次日额度约束。

## 注销、关机与锁恢复

注销保留系统级备份任务。Rofi 在重启或关机前发现正在执行或排队的备份任务时提示等待，任务结束后重新选择操作。其他关机/重启入口进入有界停止：runner 停止启动后续阶段，持续读取 Restic 输出并给予最多 25 秒清理时间；systemd 对整个服务的停止上限为 30 秒。依赖顺序让 DNS、代理和网络服务在备份之后停止，退出收尾只写本地记录。

正常信号中断有机会清除仓库锁，强制断电、无响应后端或最终强制结束仍可能留下锁。只有确认仓库仅由本机使用时，才在该目标启用 `recoverStaleLocks`。遇到 Restic exit 11 时，在持有本地互斥锁的期间读取远端锁；所有锁都属于当前主机且记录的 PID 确定不存在，才执行普通 `restic unlock` 并重试原命令一次。未知主机、仍存在的 PID 或无法完成检查时保留锁并报告失败；PID 被复用也按仍存在处理。原命令日志和 `lock-recovery.log` 分别保存诊断。

遗留的共享备份锁可以允许另一份备份完成，随后需要独占锁的检查或回收才会触发锁冲突和恢复。因此，新备份成功本身不表示所有遗留锁已经清除。

共享仓库应保持 `recoverStaleLocks = false`。人工处理前先核对所有可能访问仓库的机器和任务，再用相同运行时凭据执行普通 unlock；不使用 `--remove-all`。停止 `systemctl start` 的前台等待不等于停止作业，需要停止具体的 `site-backup-<名称>-<操作>.service`。

## 查看状态和处理失败

```sh
backup-status
systemctl list-timers 'site-backup-*'

# 按需要选择一个仓库和操作
backup_target=r2
backup_operation=backup
sudo systemctl start "site-backup-${backup_target}-${backup_operation}.service"
```

`backup_target` 使用主机已配置的目标名称；`backup_operation` 可选 `automatic`、`backup`、`check`、`restore-test` 或 `maintenance`。`automatic` 按调度策略决定是否执行，其余入口执行指定操作，无需把所有操作依次运行。

`backup-status` 读取各目标的本地执行记录和当前策略，分别公开 `backup`、`check`、`canaryRestore` 和 `maintenance` 的年龄、状态与首次截止时间，并显示当前阶段及最近的成功、失败、中断或跳过结果。`attempts` 保留实际尝试，`automatic` 给出推迟原因与 `nextEligibleAt`（Unix 秒）；这个时间还需要供电、当前窗口备份和互斥条件满足，不承诺届时必定开始。失败包含 Restic 退出码与有限长度、隐去地址和凭据的摘要。状态服务在启动时和之后每小时更新本地结果，只需目标策略与运行记录。`check` 还显示最近一次成功校验的分区及总分区数；一次分区校验或 canary 恢复不代表全部资料已验证。

| 状态 | 含义 |
| --- | --- |
| `pending` | 该目标的这项操作尚无成功记录，仍在首次等待期内 |
| `fresh` | 最近成功记录在允许期限内 |
| `stale` | 首次截止时间已到，或最近成功已超过允许期限 |
| `failed` | 最近一次操作失败，尚无后续成功 |
| `unknown` | 配置或状态无法读取、校验 |

每个 target 首次启用时，持久记录一次观察时间。默认备份等待期为 36 小时，检查与 canary 恢复为 14 天，空间回收为 45 天，各目标可覆盖。后续配置调整和重启继续沿用观察时间与执行记录。操作实际失败立即显示 `failed`，等待期不会掩盖失败。窗口外跳过保持原有健康状态。

通知投递与备份结果分别记录，通知失败不会改变备份的成功记录。桌面提示具体仓库、操作及失败、超期或未知状态；首次等待中的仓库不报警。失败通知包含阶段、Restic 退出码和错误摘要，详细原因需查看受限日志。投递、补发和通道设置见[本地通知](notifications.md)，备份与系统 journal 的保留预算见[网络日志](network.md#日志与保留)。

详细记录与最近 Restic 输出位于 root-only 的 `/var/lib/site-backup-<target>/`。`last-command.log` 按 4 MiB 轮转并保留一份旧日志；失败时先查看它和相应服务的 journal。Restic exit 3 表示有文件未读到，也按失败处理。`automatic` 入口遵守时间窗口；上面的手动操作入口可按需执行，维护仍要求接电。需跳过成功间隔时，在相同运行时凭据环境下使用 runner 的 `--force`；本地锁和自动窗口规则继续生效。

每次成功更新目标自己的状态记录；失败详情保存在受限日志中，下一次执行继续使用同一仓库与缓存。密码和访问凭据使用运行时文件。同机的多个仓库仍共享源盘、网络和凭据所在设备，离线或 Lockdown 阻断期间应关注成功时间是否过期。

同名 target 持续使用原有运行记录。更换实际仓库且需要独立运行历史时，为新仓库配置新的 target 名称，并安排初始化、验证和自动任务启用；原目标的记录保留供核对。同一仓库的访问地址或凭据调整继续使用原名称。

## 受控启用

需要核对实际云端预算时，先在待切换配置中把待观测目标的 `automatic.enable` 设为 `false`，构建并切换。仅在旧系统停止 timer 不足以保证配置激活后仍暂停；声明式禁用覆盖激活与重启。手动服务、状态和通知服务继续可用。

记录 B2 控制台 B/C、下载用量和采样时间，再执行一轮手动备份与一次到期检查：

```sh
sudo systemctl start site-backup-b2-backup.service
sudo systemctl start site-backup-b2-check.service
backup-status
sudo journalctl -u site-backup-b2-backup -u site-backup-b2-check --since today
```

确认结果文件中的开始/结束时间表明检查实际执行；成功间隔内的手动检查会跳过，需要额外检查时使用相同受限凭据环境的 runner `--force`。分别记录每步后的控制台增量，并留出控制台统计延迟。检查成功、请求和下载余量符合预期后，恢复各目标 `automatic.enable = true` 并切换配置，查看 `systemctl list-timers 'site-backup-*'` 与 `backup-status`。其他仓库按各自到期状态执行，不连跑完整检查循环来估算费用。

## 独立恢复演练

1. 从离线介质取得仓库 URL、Restic 密码、访问凭据和 SOPS/磁盘恢复资料。恢复引导所需凭据应有独立副本。
2. 选择一个提供商，用受限环境文件及密码文件连接，确认主机、快照时间、标签和范围。
3. 执行 `restic restore <snapshot-id> --target <empty-recovery-directory> --verify`，恢复到独立空目录。
4. 检查文件内容、权限和 SSH/GPG keyring；KWallet 钱包还需要原解锁密码。
5. 分别使用其余仓库演练，记录快照、范围、日期和耗时。canary 用于日常通路检查，完整资料恢复另行验证。

Tailscale 状态用于原设备停用后的身份恢复，新设备另行注册。防范恶意删除还需要提供商侧的独立账号、最小权限、离线凭据及经过 Restic 兼容验证的不可变保留；桶生命周期直接删除 packs 会破坏仓库。

参考：[文件选择](https://restic.readthedocs.io/en/stable/040_backup.html)、[仓库检查](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)、[保留与 prune](https://restic.readthedocs.io/en/stable/060_forget.html)。具体选项以锁定版本为准。
