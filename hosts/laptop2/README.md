# laptop2

这台机器使用 laptop profile，个人用户为 `ubuntu`，UID 为 1000。系统与 Home Manager 的 `stateVersion` 都保留为 `22.11`，系统时区为 `America/New_York`。

- 磁盘、LUKS、Btrfs 子卷与 swap 见 [disko.nix](disko.nix) 和[硬件配置](hardware-configuration.nix)；持久根为 `/persist`。Lanzaboote 使用已有 `/etc/secureboot` 身份。
- `/` 为 16 GiB tmpfs；`/tmp` 上限为内存的 80%。日常观察与临时大文件处理见[本机状态](../../docs/local-state.md#tmpfs-占用与临时持久化)。
- 备份仓库仅由本机使用，允许受控遗留锁恢复。各目标的频率在 [default.nix](default.nix) 中按下方账户预算设置，凭据绑定见 [secrets.nix](secrets.nix)。
- Tailscale 公告出口节点和三个 RFC1918 私网范围，同时不接受远端 DNS 与路由。实际转发仍受[网络策略](../../docs/network.md)约束。
- Docker 使用固定网桥地址，供宿主与容器共同访问构建缓存代理；更改网桥时同步调整代理监听与客户端地址，见[缓存](../../docs/cache.md)。

日常构建、升级与回退见[主机维护](../../docs/maintenance.md)。此前迁移的恢复记录见[归档](../../docs/archive/laptop2-migration.md)。

## 备份账户与预算

2026-11-07 核对的账户约束与公开规则：

| 仓库 | 预算依据 |
| --- | --- |
| B2 | 无有效付款方式，控制台 Class B/C 各有不可编辑的 2,500 次日上限，目标为免费使用。公共 PAYG 政策不能代替这个账户的硬上限；额度含义见 [Caps & Alerts](https://www.backblaze.com/docs/en/cloud-storage-data-caps-and-alerts)。 |
| R2 Standard | 以免费额度为主，可接受少量付费。存储和请求分别计费，调整频率或恢复范围前核对 [R2 定价](https://developers.cloudflare.com/r2/pricing/)。 |
| Scaleway | 付费账户，是否使用 One Zone 仍待控制台确认。成本需结合实际存储类别和下载量，见[存储定价](https://www.scaleway.com/en/pricing/storage/)。 |

当时盘点的 5 个 index、146 个 snapshots、370 个 packs，给一次新缓存检查约 151 次索引/快照读取的基础量；再加元数据 pack、选中分片的数据 pack 与控制请求。1/12 分片平均约 31 个 pack，按 pack ID 分组，实际大小和数量可不均。无重试模型按约 550 次 B 请求量级预留余量，不能视为硬上限。仓库增长后，用各操作前后的控制台增量重新校准；观测步骤见[备份预算核对](../../docs/backup.md#受控启用)。

B2 的总存储量与下载日上限仍需本机账户确认。`Today: $0.00 (7 KB)` 只表示当天用量，不能据此判断下载额度足够。下载预算需结合 pack 字节数、检查分片与维护重打包计算；手动额外操作会消费同一账户额度。
