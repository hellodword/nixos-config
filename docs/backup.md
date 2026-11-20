# 备份与恢复

每个备份目标使用独立的 Restic 仓库，分别读取源数据、加密上传并记录本地状态；单个仓库故障不影响其余目标。调整备份资料范围修改 [profiles/laptop/backup.nix](../profiles/laptop/backup.nix)，目标仓库、分片与频率在各 [主机配置](../hosts) 中声明。

## 查看状态与手动操作

```sh
backup-status
systemctl list-timers 'site-backup-*'

# 指定仓库与操作立即执行（automatic | backup | check | restore-test | maintenance）
backup_target=r2
backup_operation=backup
sudo systemctl start "site-backup-${backup_target}-${backup_operation}.service"

# 查看最近输出与服务日志
sudo journalctl -u "site-backup-${backup_target}-${backup_operation}.service" -n 80 --no-pager
sudo tail -n 80 "/var/lib/site-backup-${backup_target}/last-command.log"
```

`backup-status` 汇总各目标 `backup`、`check`、`canaryRestore`、`maintenance` 的年龄、状态与下次允许自动执行的时间（`nextEligibleAt`），并展示最近结果、Restic 退出码（脱敏摘要）及通知投递记录：

| 状态 | 含义 |
| --- | --- |
| `pending` | 尚无成功记录，仍在首次宽限期内（默认备份 36 小时、检查/恢复校验 14 天、维护 45 天） |
| `fresh` | 最近一次成功在允许期限内 |
| `stale` | 超过首次宽限期或允许成功间隔 |
| `failed` | 最近一次执行失败，尚无后续成功 |
| `unknown` | 状态或策略文件损坏不可读 |

通知投递由 `site-backup-<target>-notify.service` 独立完成（通过 `ConditionPathExistsGlob` 仅在存在 `*-pending.json` 待发记录时启动，开机及每 5 分钟自动补发），通知通道故障不会改变备份本身的成功状态。

在开发环境中可预览实际选中的文件清单与逻辑字节数（结果含个人路径，仅在本机受限目录查看）：

```sh
nix develop .#laptop --command sudo python3 scripts/backup/runner.py plan \
  --policy /etc/backup/policy.json --source /persist --state /var/lib/site-backup-plan
```

若需忽略手动操作的最小成功间隔强制执行，可在目标服务相同的运行时凭据环境下向 `runner.py` 传入 `--force`（本地互斥锁继续生效）。更换物理仓库且需全新运行历史时使用新的 target 名称；仅调整同一仓库的端点或凭据时保留原名称。

## 独立恢复演练

1. 从离线介质取得仓库 URL、Restic 密码、S3 访问凭据及 SOPS age 私钥。
2. 配置受限环境文件与密码文件，执行 `restic snapshots --tag site:<主机名>` 核对快照时间与范围。
3. 恢复至独立空目录并校验内容完整性：
   ```sh
   restic restore <snapshot-id> --target <empty-recovery-directory> --verify
   ```
4. 核对恢复出的文件内容、权限（如 `0600`/`0700`）及 SSH/GPG 密钥环；KWallet 与 Bitwarden `data.json` 仍需各自原主密码解锁。裸机全盘恢复的交接顺序见 [主机维护](maintenance.md#裸机安装与离线引导恢复)。

## 受控启用与预算核对

校准对象存储请求或下载配额时，先在主机配置中将目标仓库的 `automatic.enable` 设为 `false` 并切换系统，记录云端控制台当前用量，再手动执行单次备份与分片检查：

```sh
sudo systemctl start site-backup-b2-backup.service
sudo systemctl start site-backup-b2-check.service
backup-status
sudo journalctl -u site-backup-b2-backup -u site-backup-b2-check --since today
```

核对控制台 Class B/C 请求与下载增量符合预期后，恢复 `automatic.enable = true` 并切换配置。

## 调度与保留

| 操作 | 共享默认安排 |
| --- | --- |
| `backup` | `Asia/Shanghai` 每天 `10:10–12:00`、`21:10–23:00` 各窗口成功一次；允许电池供电 |
| `check` | 晚间窗口接交流电且本窗口备份已成功后，默认每 7 天读取 `1/12` 数据分片并推进分片号 |
| `restore-test` | 晚间窗口接交流电时，默认每 7 天恢复最新快照的 canary 文件并比对 SHA-256 |
| `maintenance` | 晚间窗口接交流电时，默认每 30 天执行（手动入口先做新备份）`forget --prune` 及回收后的完整性 `check` |

窗口计算固定使用 `Asia/Shanghai`，与主机显示时区无关。每目标由单一自动 timer 每 15 分钟在窗口内评估本地记录：先补齐当前窗口备份，再按最久未尝试顺序挑选到期重任务（`check`、`restore-test`、`maintenance`）。维护保留策略按 `--host <主机名> --tag site:<主机名> --group-by host,tags` 保留 `7 daily / 5 weekly / 12 monthly / 75 yearly` 快照（仓库内无标签历史快照独立保留；可用 `retention-plan` 预览）。

`site.backup.targets.<名称>` 支持按仓库覆盖以下策略字段：

| 配置 | 含义 |
| --- | --- |
| `schedule.timeZone`、`windows`、`retryMinutes`、`offsetMinutes` | 自动窗口、重试评估间隔及相对窗口起点的分钟偏移 |
| `automatic.enable`、`backupAttemptsPerWindow`、`heavySpacingSeconds`、`retryIntervalSeconds.<操作>` | 自动开关、单窗口最大尝试次数、重任务最小间隔及失败重试间隔 |
| `checkPartitions`、`checkWithCache` | 分片检查总片数（如 `laptop2` 的 `b2` 设为 `24`）及检查时是否传入 `--with-cache`（默认 `false`） |
| `minimumIntervalSeconds.<操作>`、`health.<操作>` | 距上次成功的最小间隔与健康超期阈值 |
| `recoverStaleLocks` | 单机独占仓库启用受控陈旧锁自动恢复 |

## 路径范围与核心必选根

备份源相对 `site.storage.persistRoot` 解析，符号链接按原链接保存而不跨越文件系统挂载边界：

| 数据范围 | 策略 |
| --- | --- |
| 核心必选根（`required = true`） | `etc/machine-id`、`etc/ssh`（主机密钥）、`var/lib/sops-nix`、`etc/secureboot`（启用 Lanzaboote 时）、用户 `.gnupg` 与 `.ssh`；任一缺失直接报错阻断空备份或残缺快照 |
| 桌面与网络持久状态 | KWallet 钱包与配置、显示器与 Fcitx5 词库/配置、Tailscale、Wi-Fi、Git 本机覆盖、代理节点与策略片段、文件服务状态、ADB 密钥 |
| 浏览器与生产力应用 | Firefox `default`/`origin` 会话与站点存储（含 SQLite WAL，排除缓存）、Bitwarden Desktop/CLI `data.json`、Anytype（排除缓存与日志）；未安装的可选应用记入 `missingOptional` |

若备份扫描后个别瞬态文件（如浏览器临时 WAL）在读取前被应用删除，导致 `restic backup --json` 返回退出码 `3`，只要快照已正常生成（含有效 `snapshot_id`）且不存在权限拒绝或 I/O 读取错误，`runner.py` 仍记录 `backup-success.json` 并在结果中标记 `partialReadWarning: true`；无快照摘要或存在权限/读取错误时一律记为失败并保留上一份成功记录。

## 注销、关机保护与陈旧锁恢复

系统级备份服务不随桌面注销停止。运行期间通过 `systemd-inhibit --what=shutdown --mode=delay` 注册关机延迟锁，同时 Rofi 电源菜单在检测到运行或排队的备份作业时提示等待；若通过系统命令触发关机，runner 停止进入后续阶段并持续排空 Restic 输出（最长 25 秒清理预算，systemd 单元停止上限 30 秒），让 Restic 正常释放远端锁并落盘 `interrupted` 记录。

强制断电或网络中断遗留远端锁并触发 Restic `exit 11` 时，开启 `recoverStaleLocks = true` 的单机独占仓库会在持有本地互斥锁的前提下检查所有远端锁：仅当全部锁均属于当前主机名，且锁记录的 PID 已不存在、或锁创建时间早于本次开机时间（`/proc/stat` `btime`）、或当前同名 PID 的 `/proc/<pid>/comm` 并非 `restic` 时，才执行普通 `restic unlock`（绝不使用 `--remove-all`）并自动重试一次；否则保留远端锁并报错，诊断写入 `lock-recovery.log`。

## 请求与下载预算参考

B2 S3 的 `GET`/`HEAD` 计入 Class B，`LIST` 计入 Class C；R2 的 `LIST`/`PUT` 计入 Class A，`GET`/`HEAD` 计入 Class B，`DELETE` 免费。下表为 Restic 在合成 S3 仓库（500 目录、2 快照、25 变更文件、无重试）上的单次请求量级参考（具体账户配额见 [laptop2 预算说明](../hosts/laptop2/README.md#备份账户与预算)）：

| 操作 | B2 Class B / C | R2 Class A / B |
| --- | --- | --- |
| 无变化备份（热 / 冷缓存） | 3 / 6；9 / 6 | 7 / 4；7 / 10 |
| 25 个文件变更备份（热缓存） | 3 / 6 | 10 / 4 |
| 分片检查（临时缓存 vs 禁用缓存） | 10 / 7 vs 537 / 7 | 7 / 11 vs 7 / 538 |
| canary 恢复（热 / 冷缓存） | 4 / 6；10 / 6 | 6 / 5；6 / 11 |
| `forget --prune`（单份合成快照） | 4 / 8 | 12 / 5 |

参考：[Restic 文件选择](https://restic.readthedocs.io/en/stable/040_backup.html)、[仓库检查](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)、[保留与 prune](https://restic.readthedocs.io/en/stable/060_forget.html)。
