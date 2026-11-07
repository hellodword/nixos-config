# 组件选择与隔离边界

组件选择以三个桌面的实际需求、可写状态和维护成本为依据。包版本由 `flake.lock` 与 nixpkgs 管理；隔离边界按维护来源、依赖复杂度、处理的外部输入和所需权限确定。

## 桌面与连接

| 能力 | 选择 | 依据 |
| --- | --- | --- |
| 桌面钱包 | KDE KSecretD / KWallet | Plasma 原生集成；Sway/i3 使用相同 Secret Service 和 PAM 登录生命周期，钱包只有一份 |
| 物理网络 | NetworkManager | Plasma 自带前端，WM 使用 nm-applet；原生支持运行时连接和 NixOS `ensureProfiles`，减少凭据文件与 DHCP 管理代码 |
| i3 显示器 | 原生 autorandr + 独立布局服务 | 保留用户方案；未知屏幕自动选首选模式。启动策略通过 XDG 配置表达，原包可复用 binary cache |
| Sway 显示器 | wdisplays + kanshi | GUI 调整并保存当前屏幕组合；kanshi 按组合恢复，状态使用上游配置格式 |
| Plasma 显示器 | KWin / KScreen | 桌面自身负责输出配置，设置保存在本机 |
| WM 壁纸 | Bing 图库 + Sway 原生背景 / feh | 获取与显示分开；复用已有图片，离线继续轮换，随显示布局更新背景 |
| GTK 外观 | 系统默认值 + 可写用户设置 | GTK 3/4 按原生配置层级读取；GTK 2 初始化可写配置，Plasma 与 WM 共用持久化偏好 |
| 应用列表 | nixpkgs Rofi | 提供两种 WM 共用的应用与命令入口、图标、计算器和表情插件 |
| 通知、状态栏、锁屏 | 各会话的原生组合 | i3 使用 X11，Sway 使用 Wayland；保留适合各协议的工具，统一操作和显示内容 |
| Firefox | Firefox + 有明确覆盖项的 Arkenfox | 通过覆盖项配置隐私偏好与登录状态，具体设置见[桌面指南](desktop.md) |
| Safe Eyes | 上游 Safe Eyes | 锁定版本已有 X11、Sway 和通用 Wayland 空闲监测实现；i3 通过 snixembed 提供上游要求的托盘协议 |
| 容器开发 | Docker | 支持 Dev Containers、现有镜像与卷；文件分享与通知服务使用 gVisor |
| 系统存储与启动 | 现有布局 | 分区、持久根、Secure Boot 身份和 stateVersion 属于现有安装约定 |

[NetworkManager keyfile](https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html) 定义连接文件及权限，[Plasma NM](https://invent.kde.org/plasma/plasma-nm) 提供 KDE 前端。[autorandr](https://github.com/phillipberndt/autorandr) 面向 XRandR；[wdisplays](https://github.com/artizirk/wdisplays) 直接保存 [kanshi](https://gitlab.freedesktop.org/emersion/kanshi) 配置；[XDG 自动启动规范](https://specifications.freedesktop.org/autostart/latest/index.html) 支持用户级 `Hidden=true` 覆盖。[Arkenfox 的选择指南](https://github.com/arkenfox/user.js/wiki/1.1-To-Arkenfox-or-Not) 明确要求按使用需求决定采用范围与覆盖项。

## 权限边界

桌面应用的文件访问范围集中在[桌面指南](desktop.md#应用隔离)。Firejail 保护处理外部内容的应用，复用上游 profile 并保留浏览器的原生沙箱。VS Code Dev Containers 和 Kitty 需要完整开发环境，由常规桌面入口运行。

后台桌面服务以 systemd 隔离各自的 home 状态和运行目录。dnsdist、dnsproxy、DNS Collector、oranc 处理网络输入，使用独立身份、只读系统及设备/能力限制；LuaJIT 所需的内存执行能力仅对 dnsdist 保留。sing-box 持有管理自身 TUN 所需的网络能力，配置生成先在无网络、只读输入的独立沙箱完成，发布进程仅控制声明的服务。

Restic 按仓库分离可写状态与 cache，源目录只读。Apprise/Bark 使用各自的 gVisor 容器和运行时凭据，Waydroid 使用上游 LXC 边界。常见基础服务继续使用 NixOS 上游单元定义。

桌面 Firejail 包装保留原包和桌面资源。默认 profile 来自锁定的 nixpkgs；Anytype 复用上游 Electron 公共配置。服务的限制由 systemd 表达，源码不承担隔离策略。文件访问入口见[桌面指南](desktop.md)，实现位于 `home/sandbox.nix`、`lib/service-hardening.nix`、`lib/desktop-service-hardening.nix` 及对应服务模块。

[Anytype](https://github.com/anyproto/anytype-ts) 的客户端和本地服务由不同语言组件构成；[oranc](https://github.com/linyinfeng/oranc) 适合现有 OCI 缓存用途，通过权限边界限制其可接触的数据。[Firejail 文档](https://firejail.wordpress.com/documentation-2/) 和 [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) 说明各限制的含义。

[Safe Eyes 的托盘说明](https://github.com/slgobinath/safeeyes/wiki/How-to-install-backend-for-Safe-Eyes-tray-icon) 推荐在 i3 使用 snixembed。它只随 i3 会话运行；Safe Eyes 在图形环境和托盘服务就绪后启动。

[GTK 3](https://docs.gtk.org/gtk3/class.Settings.html) 和 [GTK 4](https://docs.gtk.org/gtk4/class.Settings.html) 定义系统默认值与用户配置的读取顺序；[KDE 的 GTK 2 配置器](https://invent.kde.org/plasma/kde-gtk-config/-/blob/master/kded/config_editor/gtk2.cpp) 直接重建目标文件，因此 GTK 2 使用持久化目录中的普通文件。

图形用户服务仍使用会话 socket，包括用户 D-Bus 和窗口管理器 IPC；这些接口保留了会话级权限，文件系统限制约束的是进程的直接访问。X11 还允许较广泛的窗口与输入访问。因此，这些服务与桌面会话处于同一信任范围。Firejail 应用另外使用各自的 D-Bus 规则；文件选择器可见范围由其文件系统视图决定。

`kernel.io_uring_disabled=1` 将 io_uring 留给具有 `CAP_SYS_ADMIN` 的进程；普通用户及受限应用使用其他 I/O 接口。这一设置减少桌面进程可达的内核接口，不代表 io_uring 在所有场景均不适用。wheel 的文件描述符 soft limit 为 524288、hard limit 为 unlimited，Docker 单元使用 infinity；这些限额不授予文件访问权限，实际打开文件仍受内核上限、权限与可用资源约束。
