# 桌面使用与排障

SDDM 提供 Sway、i3 和 Plasma，默认 Sway。会话登录时加载用户配置并启动对应后台服务，退出时清理这些服务。

登录界面使用 `site-breeze`，保留用户、会话和键盘布局选择，以及重启、关机入口；不显示睡眠、休眠或虚拟键盘。主题由锁定版本的 Breeze 资源独立生成，KDE、Qt 和 SDDM 原包的 derivation 保持不变，可继续使用原有 binary cache。

| 服务 | Sway | i3 | Plasma |
| --- | --- | --- | --- |
| 状态栏 | Waybar | i3bar + i3status-rust | Plasma panel |
| 通知 | Mako | Dunst | Plasma |
| 锁屏 | swaylock + swayidle | i3lock + xss-lock | KScreenLocker |
| 显示器 | wdisplays + kanshi | ARandR + autorandr | KScreen/KWin |
| 门户 | gtk + wlr 截屏/共享 | gtk | kde + gtk |
| PolicyKit | KDE agent | KDE agent | Plasma 自带 |
| 网络连接 | nm-applet | nm-applet | Plasma 网络面板 |

共用 PipeWire/WirePlumber、Fcitx、Noto/CJK SC 字体与 Sarasa Term SC 等宽字体。GTK/Qt 使用桌面原生外观，光标统一为 Breeze 24；Kitty、WM 和状态栏使用项目配色。Secret Service 由 KDE KSecretD 提供，三个会话共用 KWallet。Plasma 布局与配色保存在本机。三个会话均在空闲一分钟后锁屏，挂起时锁屏，并立即要求密码。

Plasma 的 Baloo 文件索引关闭；Dolphin 按目录浏览文件，KRunner 继续提供应用和命令入口。

GTK 3/4 的字体与光标默认值位于 `/etc/xdg/gtk-{3,4}.0/settings.ini`，用户设置保存在持久化的 `~/.config/gtk-{3,4}.0/`。GTK 2 使用 `~/.config/gtk-2.0/gtkrc`，首次初始化写入默认值，之后由桌面和用户维护。Plasma 的外观设置可以正常更新这些文件；三个版本的设置文件均纳入精确备份。

[GTK 3](https://docs.gtk.org/gtk3/class.Settings.html) 和 [GTK 4](https://docs.gtk.org/gtk4/class.Settings.html) 定义系统默认值与用户配置的读取顺序；[KDE 的 GTK 2 配置器](https://invent.kde.org/plasma/kde-gtk-config/-/blob/master/kded/config_editor/gtk2.cpp) 直接重建目标文件，因此 GTK 2 使用持久化目录中的普通文件。

## 注销与电源操作

Sway/i3 的 Super+Shift+P 打开电源菜单，也可运行 `desktop-power`。菜单提供 Log out、Reboot、Power off。执行前列出仍在运行的 Firefox、Chrome/Chromium、VS Code、Bitwarden 和 VirtualBox/QEMU 虚拟机，以应用名、进程数和 PID 展示；重启与关机还检查其他用户的虚拟机，以及正在执行或排队的备份、检查、恢复演练和仓库维护任务。

有上述工作时，关闭提示框，正常退出应用或等待任务结束，再次打开菜单。菜单不会结束这些进程，也不提供强制继续。检查通过后显示确认，默认选择 Cancel；确认执行前再次检查。进程检查用于提醒仍在运行的工作，不能判断文档是否已保存。重启与关机也遵守 logind 的 inhibitor。

Log out 通过当前桌面的原生接口退出：Sway 使用 `swaymsg exit`，i3 使用 `i3-msg exit`，Plasma 使用自身的 Shutdown D-Bus 接口。注销完成后回到 SDDM，在会话选择器中选择 Sway、i3 或 Plasma，再登录。Super+Shift+E 保持 WM 原生退出确认，不经过电源菜单的进程检查。

注销会结束当前图形会话及其窗口，桌面专属服务、通知和 portal 随会话停止。系统服务和系统级备份任务不随图形注销停止。普通用户服务是否继续取决于其所属 target、其他登录会话和用户管理器生命周期；关闭桌面终端前，应将需要继续运行的任务放入适当的服务中。新桌面重新建立图形环境，应用的恢复能力由应用自身决定。

## 锁屏与启动解锁

Sway 和 i3 使用固定的深蓝紫色几何渐变背景，不跟随随机桌面壁纸，不显示时钟或日期。背景随系统配置构建，离线也可使用。Super+semicolon 和一分钟空闲锁屏共用 `desktop-lock`，密码验证分别由原生 swaylock 和 i3lock 的 PAM 接口完成。Sway 按每块屏幕填充背景；i3 按当前显示布局为各输出裁切和拼接，包括旋转屏幕。i3 的图片准备受时间限制，失败时用相同配色的纯色背景继续锁屏。Plasma 使用自己的锁屏设置。

启动时由 Plymouth Breeze 显示 LUKS 解锁提示，主机在 initrd 中配置对应的显示驱动，供早期图形显示使用。输入现有磁盘密码后继续启动至 SDDM，再输入用户登录密码；磁盘解锁和桌面登录使用各自的凭据。Esc 可切换启动详情，图形提示不可用时使用文本提示排障。Plymouth 配置进入 initrd，需要安装启动代次并重启才能验收。LUKS 设备和 Lanzaboote/Secure Boot 的签名身份沿用现有声明。

## 桌面密码钱包

Chrome、VS Code 和 Bitwarden Desktop 通过标准 Secret Service 使用 KSecretD。KWallet Manager 可查看和管理条目。默认密码钱包为 `kdewallet`，密码与系统登录密码一致时，SDDM 密码登录通过 PAM 自动解锁；Sway、i3 在显示环境就绪后完成相同初始化。自动登录没有登录密码可供钱包解锁，需要手动解锁。

钱包保存在 `~/.local/share/kwalletd/`，偏好保存在可写的 `~/.config/kwalletrc`，两者持久化并纳入 Restic。恢复钱包后使用其原密码解锁；修改系统登录密码后，可在 KWallet Manager 中同步修改钱包密码。

```sh
busctl --user status org.freedesktop.secrets
wallet_path=$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service ReadAlias s default | cut -d '"' -f 2)
busctl --user get-property org.freedesktop.secrets "$wallet_path" \
  org.freedesktop.Secret.Collection Locked
```

`Locked` 为 `false` 表示默认钱包已经解锁。`ReadAlias` 返回 `/` 时尚未设定默认钱包，可在 KWallet Manager 中创建或选择 `kdewallet`。PAM 初始化服务完成后会退出；判断解锁状态使用 Secret Service 的 collection 属性或实际应用读取。KWallet Manager 的 Open 操作会打开管理视图；[兼容接口的 `isOpen`](https://github.com/KDE/kwallet/blob/v6.31.0/src/runtime/kwalletd/kwalletd.cpp) 查询该接口已登记的访问句柄。

### 未决问题

**KWallet 偶发读回失败。**

真机曾出现钱包条目偶发无法读回；i3 VM 也在重新登录后出现读回退出码 1，触发条件尚未确定。复现时记录桌面会话、应用、登录方式、Secret Service 的锁状态和相关 journal，避免记录条目内容。桌面 VM 保留存取与重新登录场景，单次通过不足以关闭这个问题。

## 随机壁纸

Sway 和 i3 复用 `~/Pictures/wallpaper` 中的 JPEG、PNG、WebP、BMP 图片；原有非 Bing 图片同样参与随机选择。显示环境就绪后立即恢复上次壁纸，没有可用记录时从本地图库选择。会话内每 30 分钟换一张，有多张图片时避开上一张。所有显示器使用同一张图片，按 fill 裁切填满；Plasma 在系统设置中管理壁纸。

当前图片保存在 `~/.local/state/site-wallpaper/current`，最近下载尝试、成功时间和结果保存在同目录的 `fetch.json`；这些状态与图库均跨注销、重启保留。下载检查按上次尝试后一小时到期，成功、没有新图和失败都计入间隔。登录恢复剩余等待时间；已经到期或从未下载时补一次检查，登录本身不重置间隔。

下载获取 Bing 最近八张图片，使用 HTTPS、日期文件名、图片解码校验和原子发布。下载完成且获得新的有效图片后才切换背景；下载期间、失败或没有新图时保留当前画面。本地轮换独立运行，不等待网络。图库不自动删除旧图片。

Sway 使用原生背景命令，i3 使用 feh。配置重载和显示布局变化继续应用当前图片；定时任务随 WM 会话启动和停止。可手动轮换、查看下一次下载时间和持久记录：

```sh
systemctl --user start site-wallpaper.service
systemctl --user list-timers --all 'site-wallpaper-fetch@*.timer'
cat ~/.local/state/site-wallpaper/current
jq . ~/.local/state/site-wallpaper/fetch.json
journalctl --user -u site-wallpaper -u site-wallpaper-apply \
  -u site-wallpaper-fetch -u site-wallpaper-schedule -b
```

## 常用操作

Sway/i3 的快捷键：

| 快捷键 | 操作 |
| --- | --- |
| Super+Enter | Kitty |
| Super+D / Super+Shift+D | Rofi 应用列表 / 命令列表 |
| Super+H/J/K/L 或方向键 | 移动焦点；加 Shift 移动窗口 |
| Super+S / W / E | 堆叠 / 标签 / 切分布局 |
| Super+B / V | 横向 / 纵向切分 |
| Super+A | 焦点移到父容器 |
| Super+R | 调整大小模式；Enter / Escape 返回 |
| Super+减号 / Super+Shift+减号 | 显示 / 移入 scratchpad |
| Super+1…9 | 切换工作区；加 Shift 移动窗口到工作区 |
| Super+semicolon | 锁屏 |
| Super+P | 调整显示器：Sway 使用 wdisplays，i3 使用 ARandR |
| Super+Ctrl+左/右 | 将工作区移到相邻屏幕；加 Shift 仅移动窗口 |
| Print / Shift+Print | 区域 / 全屏截图到剪贴板 |
| Super+Print / Super+Shift+Print | 区域 / 全屏截图保存到 Pictures |
| Super+Shift+S | 区域截图后编辑：Sway 使用 Satty，i3 使用 Flameshot |
| Super+Shift+P | 电源菜单：注销、重启、关机；检查重要进程后确认 |
| Super+Shift+E | WM 原生退出确认 |
| Super+Space | 切换输入法 |

备份属于系统服务，注销后继续运行。Rofi 的重启和关机会等待用户先完成正在执行或排队的备份任务；任务结束后重新选择动作。其他关机入口按备份服务的 30 秒停止上限中断，远端锁的清理和恢复见[备份退出行为](backup.md#注销关机与锁恢复)。

Rofi 使用 Noto Sans 16 pt，应用列表、命令列表和电源菜单共用这一字号。模式包含 `drun,run,calc,emoji`。`rofi -show calc` 可计算，使用 Rofi 的接受自定义操作键复制结果；`rofi -show emoji` 选择后复制。两种 WM 的截图按 `image/png` 写入系统剪贴板。`desktop-shot` 也可在命令行使用。

两个 WM 默认使用标签布局、纵向切分方向和居中标题，窗口间距为零。标题使用 10 pt JetBrainsMono Nerd Font，中文回退到 Noto Sans CJK SC。mpv、feh、Emulator、Waydroid 窗口默认浮动。

Waybar 和 i3status-rust 显示当前窗口标题、CPU、内存、根 tmpfs 和持久磁盘用量、系统/用户失败单元数、网络、Tailscale、音量、电量与充电状态、本地/中国时间。本地时钟使用主机时区；中国时钟固定 `Asia/Shanghai`。

Waybar 高度 24 px、字号 13 px、模块间距 4 px，工作区位于左侧、窗口标题居中、状态模块在右侧，以不同底色区分资源、网络、音频、电池和时钟；i3bar 高度同为 24 px。Waybar 标题右侧的眼睛按钮控制原生空闲抑制，初始关闭，点击后可在演示时保持活动。手动锁屏和休眠锁屏继续生效；再次点击恢复一分钟空闲锁屏。

Waybar 的有线和 Wi-Fi 分别显示，悬浮信息包含接口名、IP、网关和即时流量；Wi-Fi 另显示 SSID 与信号。Tailscale 悬浮显示本机连接状态及 Tailnet 地址。本地时钟悬浮显示日期和月历，中国时钟显示上海日期与时间。电池显示充放电状态、剩余时间和功率；内存、磁盘、音频、亮度及温度也提供对应详情。

`Failed 0/0` 表示上次采样时系统和用户均无失败单元，采样间隔一分钟；`?` 表示尚无结果，悬浮可查看系统和用户的失败单元名称。电量降至 60% 和 50% 时分别提醒，恢复充电后重新计次。温度、亮度及电池的时间和功率由设备支持情况决定。

显示器调整、Wi-Fi 和输入法偏好保存在[本机入口](local-state.md)。Plasma Wayland 使用 KWin 的“虚拟键盘”接口启动 Fcitx 5；Sway/i3 使用对应会话的自动启动项。KWin 的输入法可在“虚拟键盘”设置中选择。Sway 下 GTK 应用和 Kitty 使用 Wayland 原生输入协议，由 Fcitx 绘制候选列表；X11 GTK 应用使用 GTK 的 Fcitx 模块，Kitty 的 X11 后端通过 `GLFW_IM_MODULE=ibus` 使用兼容接口。Fcitx 提供全部 Catppuccin 配色，可在输入法配置中选择主题。

Sway/i3 先将显示环境导入用户 systemd，再启动对应会话 target 和 nm-applet；注销随会话停止。Plasma 使用自己的网络面板。

`firefox` 和桌面入口读取 `~/.config/mozilla/firefox/default`，`firefox-origin` 读取 `origin`；显式 `--profile` 或 `-P` 使用指定资料。Arkenfox 加项目覆盖项保留会话、cookie 和登录资料。Violentmonkey 的版本、URL、哈希和 ID 来自锁定的 `reproducible-violentmonkey`，`fetchurl` 保存原始签名 XPI，由 Home Manager 按 profile 安装，`origin` 保持独立。Firefox 与 Chrome 的 DNS 走系统分流。Firefox 原生搜索配置保留默认引擎、顺序和每个引擎的全部别名。VS Code 使用可写扩展目录，既支持声明式扩展也支持界面安装，扩展数据与编辑器运行状态持久化，默认设置由 `home/apps.nix` 声明。

## 音频与触控板

PipeWire 负责播放和录音，WirePlumber 管理设备与路由，提供 PulseAudio 与 64 位 ALSA 接口。浏览器会议、媒体、桌面录屏和虚拟机音频共用这套服务。Sway/i3 点状态栏音量打开 pavucontrol，Plasma 使用原生音量面板，可选择扬声器、耳机和麦克风。JACK 与 32 位 ALSA 按当前应用需求关闭。

PipeWire 的 X11 bell 模块关闭，音频服务不连接 X11/Xwayland 的响铃通道。普通播放、录音和桌面通知音继续使用 PipeWire。检查会话切换期间的崩溃时，查看整个 boot 的 journal；重新登录后用户管理器可能重建，当前服务的 `NRestarts=0` 不能代表前一会话没有重启。

Sway/i3 的触控板支持轻触点击、双指滚动，打字时暂时抑制触控板；滚动方向使用常规方向。按下触控板的机械点击仍可使用。Plasma 在系统设置中调整并保存个人偏好。

## 字体与缩放

| 用途 | 默认字体及回退 |
| --- | --- |
| 界面、无衬线正文 | Noto Sans → Noto Sans CJK SC |
| 衬线正文 | Noto Serif → Noto Serif CJK SC |
| Kitty | JetBrainsMono Nerd Font，12 pt；中文按覆盖范围回退 |
| 编辑器、通用等宽正文 | Sarasa Term SC |
| Rofi | Noto Sans → Noto Sans CJK SC，16 pt |
| Sway/i3 窗口标题 | JetBrainsMono Nerd Font → Noto Sans CJK SC，10 pt |
| Waybar | Noto Sans → Noto Sans CJK SC → Symbols Nerd Font，13 px |
| Emoji | Noto Color Emoji |
| Nerd 图标 | Symbols Nerd Font；等宽场景使用 Mono 版本 |
| 生僻字 | Jigmo / Jigmo2 / Jigmo3 → Unifont |

简体中文字形在英文界面下同样优先。正文优先使用文字字体，emoji、图标和生僻字按覆盖范围回退。GTK、Plasma 和通知读取系统字体默认值；窗口标题与状态栏使用上表的尺寸。Kitty 使用 JetBrains Mono 的等宽字形和编程连字，连字保持终端字符网格；VS Code 和通用 monospace 使用 Sarasa Term SC。浏览器通过 Fontconfig 使用通用字体。已有个人设置继续优先。

Emoji 遵循 Unicode 的文字与 emoji 表示：`☺`、`❤` 等文字形式可以是黑白，带 FE0F 的 `☺️`、`❤️` 以及默认 emoji 使用 Noto Color Emoji。字符位于 BMP 还是补充平面、UTF-8 编码占三个还是四个字节，都不能单独决定其显示样式；肤色、ZWJ、国旗和键帽还包含多个码点。Kitty 保留自动字体回退，不把整段符号范围强制映射到 emoji 字体。

i3status-rust 使用面向 Nerd Fonts 的 [`material-nf` 图标集](https://github.com/greshake/i3status-rust/blob/master/doc/themes.md)，由 Symbols Nerd Font 提供字形。

Noto 是覆盖多语言的常见系统字体选择，可参考 [Fedora 的默认字体方案](https://fedoraproject.org/wiki/Changes/DefaultToNotoFonts) 和 [Noto CJK](https://github.com/notofonts/noto-cjk)。[Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic) 的 SC 变体适合简体中文代码混排；选择 Term SC 的依据是同一字体内的中西文度量。锁定环境中的 Pango 实测覆盖 16/20/24 px、常规/粗体/斜体，中文双字与四个拉丁字符的表格行在九种组合中均对齐。这里选择的是符合本机语言与混排需求的组合。

系统使用灰度抗锯齿和轻微 hinting；缩放由各会话的显示器管理器决定。`desktop` 检查产出 Fontconfig/Pango 的 `fonts.json`、字体样张和 Sway/i3 配置校验日志；`vm-desktop` 的实际 Kitty 窗口展示中英网格、运算符连字、文字/emoji 表示和组合 emoji。外接屏的视觉大小与清晰度由真实设备验收。

## 会话排障

```sh
echo "$XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE"
login_user=$(id -un)
systemctl status "home-manager-${login_user}.service"
journalctl -b -u "home-manager-${login_user}.service"
systemctl --user status site-sway.target site-i3.target
```

Home Manager 激活报告用户文件冲突时，在 `journalctl -u "home-manager-$(id -un).service" -b` 中确认具体路径，停止所属应用，将冲突文件保存到自己选定的持久目录，再按应用入口合并配置并重启该服务。先用 `findmnt -T` 判断路径是否属于持久挂载，挂载点按其持久化声明处理。WM 和会话服务直接读取构建产物，图形登录可以继续。通知按当前会话选择进程；输入法、portal 和音频问题在对应会话 journal 中定位。Sway/i3 通过专属 target 管理生命周期，Plasma 使用自身服务；显示管理器退出触发统一清理。同一 UID 共用 systemd/D-Bus 环境，从 SDDM 选择一个图形会话使用。

桌面检查与三会话 VM 的范围见[验证指南](validation.md)。首次设备验收包括正常注销、屏幕锁、portal 共享和外接显示器。

## Shell 与日常工具

[Safe Eyes 的托盘说明](https://github.com/slgobinath/safeeyes/wiki/How-to-install-backend-for-Safe-Eyes-tray-icon) 推荐在 i3 使用 snixembed。它只随 i3 会话运行；Safe Eyes 在图形环境和托盘服务就绪后启动。

`BROWSER=firefox` 和 `TERMINAL=kitty` 为支持这些变量的 CLI 提供选择；桌面文件关联由 MIME 设置管理。Starship 保留 SSH 主机、目录、命令耗时、Nix shell、电池和 Git 本地备份入口的提示。

Kitty 默认使用 JetBrainsMono Nerd Font 12 pt，窗口内边距为零。Ctrl+Shift+加号 / 减号临时放大 / 缩小，Ctrl+Shift+Backspace 恢复配置字号；也可用 `kitty -o font_size=12` 打开单独窗口比较。Ctrl+Shift+N / Ctrl+Shift+T 从当前目录打开新窗口 / 标签。

`git backup <名称>` 在 `~/backups/git/<名称>` 建立 bare 仓库，并把它加入 origin 的推送地址，另提供 `laptop-git-backup` 推送 remote。后续 `git push origin` 会更新本地备份；没有 origin 时可用 `git backup -f <名称>`，再推送到 `laptop-git-backup`。注册命令本身不立即复制所有分支。Starship 在这个本地备份目录不存在时提示。

Shell 保留构建、哈希、Nix 查询、媒体、二维码及容器便利入口，定义集中在 `home/cli.nix`。三个 rebuild 入口使用 daemon 的临时目录；`nixos-rebuild-boot-offline` 的含义是关闭 substitute。`sing-box-log` 查看 `network` 命名空间的 journal，`sing-box-config` 查看已生成的运行配置。

`feh` 别名使用 `--scale-down --auto-zoom`，仍经过应用隔离入口。`7zaencrypt` 使用启用 unfree 编解码支持的 p7zip。`gobuild` 保留既有构建参数；Go 工具链可从项目开发环境提供。APKiD 使用原有 gVisor 容器命令。`wget`、`tcpdump`、`ipset`、`inotify-tools`、`nix-prefetch` 和 inetutils 可直接使用；OpenSSL 工具带 legacy provider 支持。

先用 `bw login` 登录账户，再调用 `bw-unlock` 解锁并将会话 token 留在当前 shell 的 `BW_SESSION`；`bw-lock` 清理变量并锁定 CLI。提示符显示 `BW_SESSION` 是否存在，实际请求仍以 Bitwarden 的状态和响应为准，token 不写入历史或提示内容。

`,` 使用 nix-index 数据库运行缺少的命令。`coderadio`、`suno-radio` 播放电台；`docker-pull-my-images` 更新本机镜像，失败时有限重试并返回失败状态。`httpserver [目录或文件]` 使用 Docker 与 gVisor 的 `runsc`，只读共享选定路径，前台运行并在退出后移除容器，监听 8000 端口。

## 应用隔离

Firefox、Chrome、Bitwarden Desktop/CLI、mpv、feh、SQLite Browser、Anytype 和 Remmina 的常规启动入口经过 Firejail。版本和预置 profile 来自当前锁定的 nixpkgs。`home/sandbox.nix` 声明应用范围与适配；`nix/firejail.nix` 生成独立启动包装，保留原包的桌面图标、MIME 类型、桌面操作和其他资源。原应用 derivation 保持不变，仍可使用其 binary cache。

| 应用 | 可用的个人文件范围 |
| --- | --- |
| Firefox、Chrome | 各自配置、缓存和下载目录；浏览器保持自身沙箱 |
| Bitwarden Desktop | 客户端配置；通过受限 D-Bus 访问桌面密钥环、输入法和文件选择器 |
| Bitwarden CLI | CLI 配置和下载目录，导出文件可写到下载目录 |
| mpv | 播放器配置及预置 profile 中的媒体目录 |
| feh | 图片、文档、下载目录和 feh 配置 |
| SQLite Browser | 应用配置和文档目录 |
| Anytype | 自身配置与文档、下载目录 |
| Remmina | 自身配置、SSH 与下载目录；SSH 用于远程连接认证 |

`/run/current-system` 保留为 NixOS 共享资源入口，供 GTK 读取输入法模块缓存、主题和其他声明式资源。持久化目录通过正常的 home 路径使用，直接访问 `persistRoot` 受到限制。图形应用按需获得输入法、通知、文件选择器及密钥环的 D-Bus 通信权限。VS Code Dev Containers 和 Kitty 使用常规启动方式，保留开发环境访问能力。

这些入口用于限制应用对会话资源的访问；用户仍可显式启动 Nix store 中的原始程序。文件选择器可选择的实际范围由 profile 的文件系统视图决定。需要扩展某个应用的访问目录时，调整对应 profile，按实际用途开放路径。

Safe Eyes、显示器适配等后台服务使用 systemd 的文件系统与权限限制；对应服务只看到各自配置目录。autorandr hooks 需要额外文件时，在服务的 `BindReadOnlyPaths` 或 `BindPaths` 中声明具体目录。组件选择及服务边界见[权限边界](architecture.md#权限边界)。
