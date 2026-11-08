# laptop2

这台机器使用 laptop profile，个人用户为 `ubuntu`，UID 为 1000。系统与 Home Manager 的 `stateVersion` 都保留为 `22.11`，系统时区为 `America/New_York`。

- 磁盘、LUKS、Btrfs 子卷与 swap 见 `disko.nix` 和硬件配置；持久根为 `/persist`。Lanzaboote 使用已有 `/etc/secureboot` 身份。
- `/` 为 16 GiB tmpfs；`/tmp` 上限为内存的 80%。日常观察与临时大文件处理见[本机状态](../../docs/local-state.md#tmpfs-占用与临时持久化)。
- 备份目标为 Scaleway、R2 和 B2，均仅由本机使用。窗口偏移分别为 0、5、10 分钟；B2 自动备份每窗口最多尝试一次，重任务至少间隔 24 小时。策略在 `default.nix`，凭据绑定在 `secrets.nix`。
- Tailscale 公告出口节点和三个 RFC1918 私网范围，同时不接受远端 DNS 与路由。实际转发仍受[网络策略](../../docs/network.md)约束。
- Docker 网桥使用 `172.17.0.1/16`。oranc 在 `172.17.0.1:37515` 提供宿主与容器共同读取的缓存代理，见[缓存](../../docs/cache.md)。

日常构建、升级与回退见[主机维护](../../docs/maintenance.md)。此前迁移的恢复记录见[归档](../../docs/archive/laptop2-migration.md)。

## 备份账户与预算

2026-11-07 核对的账户约束与公开规则：

| 仓库 | 预算依据 |
| --- | --- |
| B2 | 当前无有效付款方式，控制台 Class B/C 各有不可编辑的 2,500 次日上限，目标为免费使用。公共 PAYG 的 A/B/C 免费政策不代表此账户没有硬上限；下载免费额度依赖月均存储量。见 [B2 定价](https://www.backblaze.com/cloud-storage/pricing)及 [Caps & Alerts](https://www.backblaze.com/docs/en/cloud-storage-data-caps-and-alerts)。 |
| R2 Standard | 每月免费 10 GB-month 存储、100 万 A、1,000 万 B；公网出口免费。超出部分存储 $0.015/GB-month、A $4.50/百万次、B $0.36/百万次，计费单位向上取整。见 [R2 定价](https://developers.cloudflare.com/r2/pricing/)。 |
| Scaleway | 请求不收费，公网出口每月 75 GB 免费后 €0.01/GB；存储按实际对象类别计费。账户已付费，One Zone 类别仍待控制台确认。见 [对象存储](https://www.scaleway.com/en/object-storage/)与[存储定价](https://www.scaleway.com/en/pricing/storage/)。 |

盘点的 5 个 index、146 个 snapshots、370 个 packs，给一次新缓存检查约 151 次索引/快照读取的基础量；再加元数据 pack、选中分片的数据 pack 与控制请求。1/12 分片平均约 31 个 pack，按 pack ID 分组，实际大小和数量可不均。无重试模型按约 550 次 B 请求量级预留余量，不能视为硬上限。先保留两次日备份与现有保留期，通过各操作前后的控制台增量校准。

B2 的总存储量与下载日上限仍需本机账户确认。`Today: $0.00 (7 KB)` 只表示当天用量，不能据此判断下载额度足够。下载预算需结合 pack 字节数、检查分片与维护重打包计算；手动额外操作会消费同一账户额度。
