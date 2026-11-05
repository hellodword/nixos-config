# 本机配置

日常偏好保存在本机，修改后按下表生效。系统模块、软件版本和初始基线由仓库管理。

## 可写入口

| 内容 | 入口 | 生效方式 |
| --- | --- | --- |
| SSH 主机 | `~/.ssh/hosts.d/*.conf` | 下次连接；本机项先于加密基线，遵循 OpenSSH 首值优先规则 |
| Git 身份 | `~/.config/git/local.inc` | 下次命令；本机 include 后于加密基线 |
| GPG 本机身份 | `~/.gnupg/`、GPG agent | 私钥、智能卡 stub、ownertrust 和本机身份保留；SSH 注册由用户通过原生 GPG 命令管理 |
| Wi-Fi / 有线连接 | Plasma 网络面板、WM 托盘、`nmcli` / `nmtui` | 即时连接，自动保存后重启保留 |
| Sway 显示器 | wdisplays、`~/.config/kanshi/config` | Apply 保存当前组合；kanshi 在连接变化及登录时恢复 |
| i3 显示器 | `~/.config/autorandr/` | 输出变化时自动恢复匹配方案 |
| Plasma 显示器 | 系统设置 → 显示配置 | 原生保存到 KWin/KScreen 状态 |
| 桌面钱包 | KWallet Manager、`~/.config/kwalletrc` | 钱包与偏好持久化，密码登录时自动解锁 |
| 输入法 | Fcitx 配置工具 | 配置、词库和学习记录持久保存 |
| VS Code 扩展 | 扩展界面 | 即时安装；用户扩展目录与编辑器运行状态持久化 |
| 代理节点与独立 endpoint | `/persist/usr/local/etc/sing-box/outbounds.json` | 校验后运行 `sudo network-policy apply`，见[网络指南](network.md) |
| 共享域名 route 片段 | `/persist/usr/local/etc/network-policy/route.d/*.{json,jsonc}` | `sudo network-policy check` 后 `apply`，见[网络指南](network.md) |
| 原生连接 route 片段 | `/persist/usr/local/etc/network-policy/connection.d/*.{json,jsonc}` | 与共享片段统一排序，校验后 `apply` |

SSH、Wi-Fi、显示器、输入法与网络策略入口纳入精确备份；VS Code 目录持久化。路径中的 `/persist` 来自 `site.storage.persistRoot`；用户目录来自 NixOS 账户定义。SSH、Git 的受管主配置负责加载本机入口；编辑本机文件即可保留后续系统更新。

```sshconfig
# ~/.ssh/hosts.d/work.conf
Host work
  HostName bastion.example.net
  User developer
```

```sh
git config --file ~/.config/git/local.inc user.email you@example.net
```

## Wi-Fi

NetworkManager 管理物理网卡。Plasma 使用原生网络面板；Sway/i3 使用 nm-applet，也可以运行 `nmtui` 或 `nmcli --ask device wifi connect 'SSID'`。动态连接保存在 `/etc/NetworkManager/system-connections/`，文件为 root 所有、0600；目录持久化并纳入加密 Restic 备份。

常用连接使用 NixOS 原生 `ensureProfiles`，SSID 与密码来自 `system.sops.yaml` 中的 `wifi/environment`。完整声明与填写方法见[主机凭据](secrets.md#声明式-wi-fi)。

为每个声明式连接选择固定、唯一的 UUID。NixOS 在运行时生成 `/run/NetworkManager/system-connections/` 中的连接文件，环境变量替换发生在解密之后。常用连接的长期配置在 Nix 中修改；额外连接由 GUI/CLI 管理。要把某个声明式连接完全交给本机维护，可用 `nmcli connection clone home home-local` 创建独立 UUID，再从声明中移除原连接。

启用本项目 DNS 时，NetworkManager 只管理链路、地址和路由；关闭该 DNS 功能后使用网络提供的解析器。Mullvad、Tailscale 和容器接口由各自服务管理。

## 显示器与输入法

Sway 使用 wdisplays 调整，kanshi 恢复已保存的屏幕组合。按 Super+P 打开界面，调整分辨率、缩放、方向和位置后点 Apply；当前组合写入 `~/.config/kanshi/config` 并立即应用。文件持久化并纳入备份，也可以直接编辑后运行 `kanshictl reload`。

例如，先仅使用内屏，在 wdisplays 中保存 150% 缩放；再接办公室外屏，保存内屏在左、外屏在右且外屏 100% 的组合。下次接回同一组屏幕，kanshi 恢复第二套布局；拔掉外屏则匹配第一套。会议室外屏属于另一组，需要单独调整并保存。没有保存过的组合使用 Sway 原生首选模式、自动缩放与横向排列，内屏继续启用。

恢复按当前连接的屏幕组合匹配，不恢复应用或窗口。按 Super+Ctrl+左/右将整个工作区移到相邻屏幕，再加 Shift 只移动当前窗口，适合外屏展示而内屏继续工作。wdisplays 的 Apply 立即生效，没有定时自动回退；调整时保留一块可操作的屏幕。

i3 监听屏幕连接变化，由 autorandr 恢复已保存方案；新连接组合采用首选模式，内屏在左，其余屏幕向右排列。按 Super+P 用 ARandR 调整布局后，运行 `autorandr --save office` 保存。连接同一组屏幕或重新登录时会恢复该方案。

未知组合由 [布局脚本](../scripts/desktop/layout.py) 调用 XRandR 的原生模式选择；多个首选模式按 XRandR 顺序选择，缺少首选标记时使用其 DPI 回退。旋转、缩放和已有 panning 在自动布局时复位，个性化设置保存在 autorandr 方案里。

Plasma 使用原生显示设置，`~/.config/kwinoutputconfig.json` 等文件通过持久化链接支持原子保存。三种桌面各自管理显示状态。Plasma 的触控板偏好保存到 `~/.config/kcminputrc`，通过持久化链接支持原子保存并纳入备份。

Fcitx 用户配置位于 `~/.config/fcitx5/`，学习数据位于 `~/.local/share/fcitx5/`，包括 `pinyin/user.dict` 和 `pinyin/user.history`。`/etc/xdg/fcitx5/` 提供初始默认值；已有偏好继续生效。旧学习记录可从备份恢复。

## 修改加密基线

SSH、Git/GPG 等基线保存在 `hosts/laptop2/secrets/`，激活使用既有 `/persist/var/lib/sops-nix/keys.txt`。文件按系统、备份和身份分组，填写方式见[主机凭据](secrets.md)。

```sh
nix develop --command sops edit hosts/laptop2/secrets/identity.sops.yaml
```

基线或系统配置变化需要重新构建；解密保持在目标机运行时。身份文档以完整子密钥指纹声明 SSH 用途和 Git 签名，系统推导公钥文件和 Git 配置。首次导入、换钥及 SSH 注册使用[身份配置](secrets.md#gpgssh-与-git-身份)中的原生命令，由用户决定操作真实密钥环的时机。

## tmpfs 占用与临时持久化

laptop2 的根目录 `/` 使用 16 GiB tmpfs，`/tmp` 使用独立 tmpfs，上限为物理内存的 80%，在这台机器上约 50 GiB。`/run`、`/dev/shm` 也有各自的挂载与上限。这些数值是容量限制，按实际写入消耗内存；可换出的页面还可能使用 swap。

Firefox 配置及磁盘缓存、Chrome、Code、Docker、虚拟机、开发目录和个人文件继续写入持久盘；Fcitx 配置与词库也位于持久盘。Plasma 文件索引关闭。其他应用缓存仍可能写入根 tmpfs，需要按实际占用判断。

### 找到文件与写入者

先区分文件系统容量、inode 与系统内存压力：

```sh
df -hT / /tmp /run /dev/shm /persist
df -i / /tmp /run /dev/shm
free -h
swapon --show
sudo ncdu -x -r /
sudo ncdu -x -r /tmp
```

`ncdu -x` 留在同一文件系统，`-r` 禁用删除；扫描根目录时不会把持久盘容量算进来。找到具体路径后，检查它实际落在哪里，以及哪个进程仍在使用它：

```sh
live="$HOME/.cache/example-app"
findmnt -T "$live" -o TARGET,SOURCE,FSTYPE,OPTIONS
readlink -e "$live"
stat -c '%a %u:%g %n' "$live"
sudo lsof +D "$live"
sudo lsof +L1
```

`example-app` 换成查到的目录。`lsof +D` 只对这个具体目录执行；`+L1` 找出已删除但仍被进程打开的文件。后者的占用要等进程关闭文件才释放，正常退出应用或重启所属服务通常即可。

需要观察应用的路径访问时，先选定其 PID，再进行短时间跟踪：

```sh
sudo timeout 20s strace -f -e trace=%file -p 1234
sudo findmnt -N 1234
```

替换 PID。跟踪输出包含路径和部分系统调用参数，只在本机审阅；20 秒后跟踪结束。`findmnt -N` 查看进程自己的挂载视图，适用于 Firejail 或带文件系统隔离的服务。

如果 `df` 明显大于目录汇总，除已删除文件外，还可能有被挂载遮住的旧文件。可在独立挂载命名空间中建立根目录的只读、非递归视图：

```sh
sudo unshare --mount --propagation private bash
view=$(mktemp -d /run/tmpfs-view.XXXXXX)
mount --bind / "$view"
mount -o remount,bind,ro "$view"
ncdu -x -r "$view"
umount "$view"
rmdir "$view"
exit
```

该视图不带入 `/persist`、用户持久目录等子挂载，因此能看到被遮住的根 tmpfs 内容。先确认内容和写入者，再通过对应的正常挂载路径处理数据。

### 临时扩大容量

内存与 swap 有余量、根 tmpfs 已接近上限时，可以暂时将根目录上限调到 24 GiB：

```sh
sudo mount -o remount,size=24G /
df -hT /
```

此操作只改变本次启动的容量上限，不释放已有占用，也不增加实际内存。`/tmp` 是独立挂载，需要对 `/tmp` 单独 remount；当前默认已经是 80%。

### 把一个目录转到持久盘

下面以用户自己拥有的真实目录 `~/.cache/example-app` 为例。先退出应用或停止所属服务，并通过上面的命令确认目录位于 tmpfs、没有子挂载，也不是符号链接。服务目录应使用其实际 User/Group，以 root 身份复制并保留对应所有权。

设置三个明确路径；持久目标和暂存路径应尚未存在，已有副本先分别核对，避免把不同版本混在一起：

```sh
live="$HOME/.cache/example-app"
persistent="/persist$live"
held="$live.tmpfs-held"
printf '%s\n' "$live" "$persistent" "$held"
saved_mode=$(stat -c %a "$live")
saved_uid=$(stat -c %u "$live")
saved_gid=$(stat -c %g "$live")
```

对本例创建对应的持久父目录，然后创建一个新的目标目录。逐步执行，创建失败就先检查已有目标：

```sh
install -d -m 0700 /persist/home/ubuntu/.cache
mkdir -m 0700 "$persistent"
rsync -aHAXS --numeric-ids --one-file-system -- "$live/" "$persistent/"
rsync -naHAXSc --numeric-ids --one-file-system --itemize-changes -- "$live/" "$persistent/"
```

第二次 rsync 以校验和核对内容及元数据，正常应无差异；有差异先解决写入竞争或复制错误。权限、ACL、扩展属性、硬链接、稀疏文件及符号链接均按原样保存。

确认副本后，把原 tmpfs 目录改名保留，再创建同权限的空挂载点：

```sh
mv -T -- "$live" "$held"
install -d -m "$saved_mode" "$live"
sudo chown "$saved_uid:$saved_gid" "$live"
sudo mount --bind "$persistent" "$live"
findmnt -M "$live" -o TARGET,SOURCE,FSTYPE,OPTIONS
rsync -naHAXSc --numeric-ids --one-file-system --itemize-changes -- "$held/" "$live/"
```

核对挂载确实来自持久盘，校验无差异，再重新启动应用。应用应能读取原数据并继续写入；带独立挂载命名空间的应用或服务也需要重启，才能使用新挂载。

若 bind mount 未成功，保留持久副本；确认 `live` 仍是空目录后撤回这次改名：

```sh
rmdir "$live" && mv -T -- "$held" "$live"
```

应用验证成功后，原 tmpfs 副本仍占用内存。确认其没有打开的文件，再删除这个刚才明确改名的副本：

```sh
sudo lsof +D "$held"
```

没有打开文件且没有权限等查询错误时，执行：

```sh
rm -r -- "$held"
df -hT / "$live"
```

直接在原目录上覆盖挂载不会释放原数据占用，改名和最终释放是这一步的用途。bind mount 重启后消失，但 `/persist` 中的数据保留；重启前可把 `.cache/example-app` 加入用户持久化目录声明，或重启后再次创建挂载点并执行同一条 bind mount。持久化不自动将该目录加入 Restic 备份。

卸载临时挂载前同样先停止写入，使用 `sudo umount "$live"`。卸载不会把数据复制回 tmpfs，持久副本继续留在 `/persist`。
