# 桌面使用与排障

SDDM 提供 Sway、i3 和 Plasma，默认 Sway。会话登录时加载用户配置并启动对应后台服务，退出时清理这些服务。

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

## 桌面密码钱包

Chrome、VS Code 和 Bitwarden Desktop 通过标准 Secret Service 使用 KSecretD。KWallet Manager 可查看和管理条目。默认密码钱包为 `kdewallet`，密码与系统登录密码一致时，SDDM 密码登录通过 PAM 自动解锁；Sway、i3 在显示环境就绪后完成相同初始化。自动登录没有登录密码可供钱包解锁，需要手动解锁。

钱包保存在 `~/.local/share/kwalletd/`，偏好保存在可写的 `~/.config/kwalletrc`，两者持久化并纳入 Restic。恢复钱包后使用其原密码解锁；修改系统登录密码后，可在 KWallet Manager 中同步修改钱包密码。

```sh
busctl --user status org.freedesktop.secrets
journalctl --user -u plasma-kwallet-pam.service -b
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
| Super+Shift+P | 电源菜单；注销、重启、关机需确认，遵守 logind inhibitors |
| Super+Shift+E | 退出会话确认 |
| Super+Space | 切换输入法 |

Rofi 模式包含 `drun,run,calc,emoji`。`rofi -show calc` 可计算，使用 Rofi 的接受自定义操作键复制结果；`rofi -show emoji` 选择后复制。两种 WM 的截图按 `image/png` 写入系统剪贴板。`desktop-shot` 也可在命令行使用。

两个 WM 默认使用标签布局、纵向切分方向和居中标题。mpv、feh、Emulator、Waydroid 窗口默认浮动。

Waybar 和 i3status-rust 显示当前窗口标题、CPU、内存、根 tmpfs 和持久磁盘用量、系统/用户失败单元数、网络、Tailscale、音量、电量与充电状态、UTC/中国时间。`Failed 0/0` 表示上次采样时系统和用户均无失败单元，采样间隔一分钟；`?` 表示尚无结果。电量降至 60% 和 50% 时分别提醒，恢复充电后重新计次。温度和亮度由设备支持情况决定。Tailscale 信息表示本机连接状态。

显示器调整、Wi-Fi 和输入法偏好保存在[本机入口](local-state.md)。Plasma Wayland 使用 KWin 的“虚拟键盘”接口启动 Fcitx 5；Sway/i3 使用对应会话的自动启动项。已有 KWin 配置若选择了其他输入法，可在“虚拟键盘”设置中重新选择 Fcitx 5。Kitty 的 X11 后端通过 `GLFW_IM_MODULE=ibus` 使用 Fcitx 的兼容接口；Wayland 后端使用会话的原生输入协议。

`firefox` 和桌面入口读取 `~/.config/mozilla/firefox/default`，`firefox-origin` 读取 `origin`；显式 `--profile` 或 `-P` 使用指定资料。Arkenfox 加项目覆盖项保留会话、cookie 和登录资料。Violentmonkey 的版本、URL、哈希和 ID 来自锁定的 `reproducible-violentmonkey`，`fetchurl` 保存原始签名 XPI，由 Home Manager 按 profile 安装，`origin` 保持独立。Firefox 与 Chrome 的 DNS 走系统分流。Firefox 原生搜索配置保留默认引擎、顺序和每个引擎的全部别名。VS Code 使用可写扩展目录，既支持声明式扩展也支持界面安装，扩展数据与编辑器运行状态持久化，默认设置由 `home/apps.nix` 声明。

## 音频与触控板

PipeWire 负责播放和录音，WirePlumber 管理设备与路由，提供 PulseAudio 与 64 位 ALSA 接口。浏览器会议、媒体、桌面录屏和虚拟机音频共用这套服务。Sway/i3 点状态栏音量打开 pavucontrol，Plasma 使用原生音量面板，可选择扬声器、耳机和麦克风。JACK 与 32 位 ALSA 按当前应用需求关闭。

Sway/i3 的触控板支持轻触点击、双指滚动，打字时暂时抑制触控板；滚动方向使用常规方向。按下触控板的机械点击仍可使用。Plasma 在系统设置中调整并保存个人偏好。

## 字体与缩放

| 用途 | 默认字体及回退 |
| --- | --- |
| 界面、无衬线正文 | Noto Sans → Noto Sans CJK SC |
| 衬线正文 | Noto Serif → Noto Serif CJK SC |
| 终端、编辑器、等宽正文 | Sarasa Term SC |
| Emoji | Noto Color Emoji |
| Nerd 图标 | Symbols Nerd Font；等宽场景使用 Mono 版本 |
| 生僻字 | Jigmo / Jigmo2 / Jigmo3 → Unifont |

简体中文字形在英文界面下同样优先。正文优先使用文字字体，emoji、图标和生僻字按覆盖范围回退。GTK、Plasma、窗口管理器、通知和状态栏读取同一字体默认值；Kitty 与 VS Code 共用等宽字体，浏览器通过 Fontconfig 使用通用字体。已有个人设置继续优先。

i3status-rust 使用面向 Nerd Fonts 的 [`material-nf` 图标集](https://github.com/greshake/i3status-rust/blob/master/doc/themes.md)，由 Symbols Nerd Font 提供字形。

Noto 是覆盖多语言的常见系统字体选择，可参考 [Fedora 的默认字体方案](https://fedoraproject.org/wiki/Changes/DefaultToNotoFonts) 和 [Noto CJK](https://github.com/notofonts/noto-cjk)。[Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic) 的 SC 变体适合简体中文代码混排；选择 Term SC 的依据是同一字体内的中西文度量。锁定环境中的 Pango 实测覆盖 16/20/24 px、常规/粗体/斜体，中文双字与四个拉丁字符的表格行在九种组合中均对齐。这里选择的是符合本机语言与混排需求的组合。

系统使用灰度抗锯齿和轻微 hinting；缩放由各会话的显示器管理器决定。`desktop` 检查产出 `fonts.json`、字体样张和 Sway/i3 配置校验日志；实际会话截图由 VM 检查生成，覆盖英文 locale 下的 SC 字形、混排宽度、图标和 emoji。外接屏的视觉大小与清晰度由真实设备验收。

## 会话排障

```sh
echo "$XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE"
systemctl status home-manager-ubuntu.service
journalctl -b -u home-manager-ubuntu.service
systemctl --user status site-sway.target site-i3.target
```

Home Manager 激活报告用户文件冲突时，在 `journalctl -u home-manager-ubuntu.service -b` 中确认具体路径，停止所属应用，将冲突文件保存到自己选定的持久目录，再按应用入口合并配置并重启该服务。先用 `findmnt -T` 判断路径是否属于持久挂载，挂载点按其持久化声明处理。WM 和会话服务直接读取构建产物，图形登录可以继续。通知按当前会话选择进程；输入法、portal 和音频问题在对应会话 journal 中定位。Sway/i3 通过专属 target 管理生命周期，Plasma 使用自身服务；显示管理器退出触发统一清理。同一 UID 共用 systemd/D-Bus 环境，从 SDDM 选择一个图形会话使用。

桌面检查与三会话 VM 的范围见[验证指南](validation.md)。首次设备验收包括正常注销、屏幕锁、portal 共享、外接显示器及休眠。当前保留的随机加密 swap 对应 suspend 使用方式。

## Shell 与日常工具

`BROWSER=firefox` 和 `TERMINAL=kitty` 为支持这些变量的 CLI 提供选择；桌面文件关联由 MIME 设置管理。Starship 保留 SSH 主机、目录、命令耗时、Nix shell、电池和 Git 本地备份入口的提示。

Kitty 的 Ctrl+Shift+N / Ctrl+Shift+T 从当前目录打开新窗口 / 标签。

`git backup <名称>` 在 `~/backups/git/<名称>` 建立 bare 仓库，并把它加入 origin 的推送地址，另提供 `laptop-git-backup` 推送 remote。后续 `git push origin` 会更新本地备份；没有 origin 时可用 `git backup -f <名称>`，再推送到 `laptop-git-backup`。注册命令本身不立即复制所有分支。Starship 在这个本地备份目录不存在时提示。

Shell 保留构建、哈希、Nix 查询、媒体、二维码及容器便利入口，定义集中在 `home/cli.nix`。三个 rebuild 入口使用 daemon 的临时目录；`nixos-rebuild-boot-offline` 的含义是关闭 substitute。`sing-box-log` 查看 journal，`sing-box-config` 查看已生成的运行配置。

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

Safe Eyes、显示器适配等后台服务使用 systemd 的文件系统与权限限制；对应服务只看到各自配置目录。autorandr hooks 需要额外文件时，在服务的 `BindReadOnlyPaths` 或 `BindPaths` 中声明具体目录。组件选择及服务边界见[选择与隔离边界](choices.md)。
