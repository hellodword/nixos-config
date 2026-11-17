# 主机凭据

笔记本的 `hosts/<主机>/secrets.nix` 选择凭据目录、用户、备份目标和 Wi-Fi 连接，`lib/credentials.nix` 负责共享字段绑定。通用模块只接收运行时文件路径。SOPS 使用持久根下 `var/lib/sops-nix/keys.txt` 中的 age 身份解密，运行时文件由 sops-nix 管理。

VPS 使用[加密 inventory](vps.md#建立私有-inventory)，维护机解密后通过 Colmena 分发节点专属的运行凭据。订阅地址、证书 Worker 凭据，以及撤销与换钥顺序也在该指南中维护。

主机凭据和 VPS inventory 均采用 SOPS 原生 YAML：字段名可见，秘密值加密。节点等标识作为 YAML 键时也会保留可读，因此使用适合公开的名称。

| 密文 | 内容 | 消费者 |
| --- | --- | --- |
| `system.sops.yaml` | 登录密码 hash、Tailscale auth key、Wi-Fi 环境文件、Bark device token、额外通知通道、文件服务账号与证书地址；可选的个人资料 | 用户创建、Tailscale、NetworkManager、通知与文件服务 |
| `backup.sops.yaml` | Restic 密码，以及各目标的仓库地址和环境文件 | 各仓库独立 Restic 作业 |
| `identity.sops.yaml` | OpenPGP 公钥证书、命名子密钥、SSH hosts 与 Git 身份 | SSH、Git |

多行配置使用 YAML 的 `|` 字符串，例如 `repositories/r2/environment` 对应一个完整环境文件。完整身份文档由 root 读取，再发布对应用户可读的 SSH/Git 配置和公钥文件，权限为 `0400`；其余凭据默认由 root 持有，登录密码 hash 在创建用户前提供。

## 创建与编辑

公开示例在 `data/secrets/`，使用合成值或空字段。创建自己的 age 身份，将公钥写入 `.sops.yaml` 对应路径规则的 `age` 接收者；新增主机时添加匹配规则。私钥放在系统配置指定的 `sops.age.keyFile` 路径，由 root 持有、权限为 `0600`，并另存离线备份。

laptop 会话通过 `SOPS_AGE_KEY_CMD` 读取该密钥：SOPS 和编辑器以当前用户运行，读取密钥时按现有 sudo 规则认证。会话设置在切换系统配置并重新登录后生效，`laptop` 和 `vps` 开发环境都会继承。

从仓库根目录创建或编辑凭据：

```sh
host=laptop2  # 换成要编辑的主机
sops "hosts/$host/secrets/system.sops.yaml"
```

`backup.sops.yaml`、`identity.sops.yaml` 和 `secrets/vps.sops.yaml` 使用相同方式。新建文件时，在编辑器中用对应示例替换初始内容并填写；保存时 SOPS 将加密结果写入目标文件。新建时按 `.sops.yaml` 选择接收者，文件格式由 `.yaml` 扩展名确定。

向其他程序提供 YAML 时使用 `sops decrypt <密文路径>`。只确认解密与完整性校验时，将输出重定向到 `/dev/null`。

## 新用户填写

| 字段 | 填写方式 |
| --- | --- |
| `login/passwordHash` | 在本地运行 `nix develop .#laptop --command mkpasswd -m yescrypt`；输入登录密码，保存生成的 hash |
| `tailscale/authKey` | Tailscale 管理控制台生成的设备注册 key；按设备归属设置有效期与 tags。已有设备身份由持久状态保存 |
| `wifi/environment` | systemd EnvironmentFile 格式，保存 SSID 和密码；示例使用单引号处理空格 |
| `notifications/barkDeviceToken` | Bark 客户端的 APNs device token，区别于服务端生成的 device key |
| `notifications/channels` | 原生 Apprise YAML 字符串，示例包含三个带 tag 的通道；仅使用 Bark 时填 `urls: []`，通道说明见[通知](notifications.md) |
| `files/adminPassword`、`files/userPassword` | 两个独立的长随机密码，供 HTTPS 与 SMB 使用；启用与证书签发见[文件服务](files.md) |
| `files/certificateNames` | 实际访问的域名与 IP 数组；按[文件服务](files.md#首次配置)填写并手动签发 |
| `password`、`repositories/*/url` | Restic 仓库密码和对象存储控制台给出的 S3 endpoint、bucket、仓库前缀；恢复既有仓库必须使用原密码 |
| `repositories/*/environment` | 对应提供方的 S3 access key/secret；限定到该备份 bucket 所需权限 |
| `gpg/publicKeys` | 包含所选子密钥的完整 OpenPGP 公钥证书，可填写多个 ASCII armor 公钥块 |
| `gpg/ssh` | 用途名到认证子密钥完整指纹的映射，如 `github`、`ios`；未使用时填 `{}` |
| `gpg/signingKey` | 签名子密钥的完整指纹；未使用时填 `null` |
| `ssh/hosts`、`git/identity` | 原生 SSH/Git 配置，多行字符串；未使用时可留空 |
| `retained` | 可选的个人资料；保存原有内容，没有启用服务的副作用 |

新用户需要同时调整主机用户名和备份目标。SSH 用途直接在身份文档中增加，无需修改 Nix 绑定。新安装的磁盘和启动配置需要单独设计，见[新增主机](maintenance.md#增加主机)。

## GPG、SSH 与 Git 身份

`gpg.publicKeys` 是公钥事实源，`gpg.ssh` 和 `gpg.signingKey` 选择其中的子密钥。用以下命令查看完整子密钥指纹、长 Key ID 和用途：

```sh
gpg --list-keys --keyid-format long --with-subkey-fingerprint --with-keygrip
```

SSH 选择 `[A]` 子密钥，Git 签名选择 `[S]` 子密钥。系统从证书推导 keygrip、SSH 公钥和文件名 `/etc/ssh/gpg.<用途>.<16 位长 Key ID>.pub`。`ssh.hosts` 中的 `IdentityFile` 使用这个完整路径，格式与普通 OpenSSH 配置相同；更换子密钥时，同步修改声明指纹与对应路径。填写方式见[身份示例](../data/secrets/identity.example.yaml)。

解密后，`site-identity.service` 在隔离公钥环中生成一整组文件，再切换 `/run/site-identity/<用户名>/current`；生成失败时保留上一组可用文件。`current/manifest.json` 给出每个用途的完整指纹、keygrip 和公钥文件名。

用户级 `site-gpg-ssh-identities.service` 读取清单，把本机 GPG 已有的认证子密钥通过 `Use-for-ssh` 属性启用给 SSH。用户服务启动、身份发布代次切换和 `~/.gnupg/private-keys-v1.d` 变化时自动执行；已有非零优先级继续生效，登记属性随 GPG 目录持久保存。

SSH 使用 GPG 子密钥完成签名：秘密部分保存在本机 GPG 中或智能卡上，`.pub` 文件负责选择对应身份。`~/.gnupg` 持久化并纳入备份。首次接入或更新公钥证书时，在自己的用户会话中审阅并导入：

```sh
identity="/run/site-identity/$(id -un)/current"
gpg --show-keys --with-subkey-fingerprint --with-keygrip "$identity/public.asc"
gpg --import "$identity/public.asc"
gpg --list-secret-keys --with-subkey-fingerprint --with-keygrip
jq . "$identity/manifest.json"
```

智能卡身份通过 `gpg --card-status` 建立本机引用。声明的子密钥缺少本机 GPG 密钥或智能卡引用时，注册服务逐项记录用途、指纹和原因，继续启用其余可用身份，并由桌面健康通知提示失败状态。补齐资料后自动重试；也可立即重试并核对 SSH 提供的身份：

```sh
systemctl --user restart site-gpg-ssh-identities.service
journalctl --user -u site-gpg-ssh-identities.service -b
ssh-add -L
ssh -T git@github.com
```

`IdentityFile` 指向公钥文件时，需要 agent 提供对应签名身份。若出现 `Load key "…pub": invalid format`，先比较清单、公钥与 `ssh-add -L`，再查看注册服务日志。[OpenSSH IdentityFile](https://man.openbsd.org/ssh_config#IdentityFile) 说明了公钥选择 agent 身份的用法。

换钥时先在本机 GPG 准备好新子密钥，在远端登记新公钥，再把新证书、子密钥指纹与 `IdentityFile` 路径写入身份文档并部署。注册服务自动启用新身份，旧身份和本机额外身份继续可用。确认远端连接成功，且旧子密钥已从 `gpg.ssh` 的所有用途中撤下后，再手动停用旧 keygrip：

```sh
gpg-connect-agent 'KEYATTR 旧KEYGRIP Use-for-ssh: false' /bye
```

若 `~/.gnupg/sshcontrol` 仍有同一 keygrip 的注册，先保存该文件，再手动删除对应行或在行首加 `!`。用 `ssh-add -L` 核对最终身份列表；智能卡还受 GnuPG 的活动卡选择规则影响。自动注册保留 `sshcontrol` 内容，GPG 密钥导入、信任和智能卡 PIN 由本人管理。身份选择规则见 [GnuPG agent](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html)。

Git 的 `user.signingKey` 使用完整签名子密钥指纹加 `!`。需要签名的仓库运行 `git signing`；本机 `~/.config/git/local.inc` 最后加载。SSH 先加载 `~/.ssh/hosts.d/*.conf`，普通选项遵循首值优先，`IdentityFile` 按原生规则累计。

```sh
journalctl -u site-identity.service -b
ssh -G github.com
git config --show-origin --get user.signingkey
git verify-commit HEAD
```

### 口令缓存

软件私钥的口令由本人在 Pinentry 中输入，GPG agent 在内存中缓存；Pinentry 的外部口令缓存已关闭。普通 GPG 操作与 SSH 身份的缓存均为空闲 4 小时、最长 24 小时：使用对应缓存会刷新空闲计时，最长时限从该条缓存建立时计算。不同身份可能分别要求输入口令。[GnuPG 的缓存选项](https://www.gnupg.org/documentation/manuals/gnupg/Agent-Options.html)说明了两种时限的含义。

日常时长在 [CLI 模块](../modules/core/cli.nix)中声明。个人 `~/.gnupg/gpg-agent.conf` 在系统配置之后读取，可覆盖这些值；如果仍频繁询问，检查其中的 TTL 和 `ignore-cache-for-signing`，以及旧 `sshcontrol` 中是否为某个 keygrip 指定了单独的 TTL。

切换系统配置后，在自己的用户会话中让已运行的 agent 读取新时长。此命令也用于随时清空 GPG 和 SSH 口令缓存：

```sh
gpgconf --reload gpg-agent
```

下一次使用私钥时重新输入口令。重载、退出或重启 agent 都会清空缓存；已建立的 SSH 连接及其连接复用不受影响。

### 临时长缓存

需要长时间工作时，可在自己的用户会话中执行以下命令，将四个时限设为 `2147483647` 秒（约 68 年），实际持续到缓存被清空或 agent 退出。运行时文件只包含配置，口令仍由 Pinentry 手动输入。

```sh
(
  umask 077
  {
    gpg_home=$(gpgconf --list-dirs homedir)
    if [ -f "$gpg_home/gpg-agent.conf" ]; then
      cat "$gpg_home/gpg-agent.conf"
    fi
    printf '\n'
    cat <<'EOF'
default-cache-ttl 2147483647
default-cache-ttl-ssh 2147483647
max-cache-ttl 2147483647
max-cache-ttl-ssh 2147483647
EOF
  } > "$XDG_RUNTIME_DIR/gpg-agent-session.conf"
)

systemctl --user edit --runtime --stdin \
  --drop-in=90-cache-session.conf gpg-agent.service <<'EOF'
[Service]
ExecStart=
ExecStart=/run/current-system/sw/bin/gpg-agent --supervised --options %t/gpg-agent-session.conf
EOF
systemctl --user restart gpg-agent.service
```

系统配置仍会读取，个人配置在启用时复制到运行时文件，末尾的四个值决定缓存时长。启用时重启 agent，下一次使用各身份时需要输入口令。此后 `gpgconf --reload gpg-agent` 可清空缓存并保留长缓存策略；运行时策略在重启机器或用户运行时目录被回收后消失。

提前恢复日常策略：

```sh
rm -f -- "$XDG_RUNTIME_DIR/gpg-agent-session.conf" \
  "$XDG_RUNTIME_DIR/systemd/user/gpg-agent.service.d/90-cache-session.conf"
systemctl --user daemon-reload
systemctl --user restart gpg-agent.service
```

### 缓存期间的身份权限

延长缓存增加了程序能够使用私钥的时间。能访问用户 agent socket 的进程可以请求签名、SSH 认证或解密，未必需要先获知口令或导出私钥。因此，同用户运行的恶意程序是主要风险；向容器挂载 agent socket 或向远端转发 agent，也会授予相应的身份使用能力。项目默认关闭 SSH agent 转发，单独持有 `/etc/ssh/gpg.*.pub` 文件只提供公钥。

缓存时长不能隔离已取得 root、内核或进程内存访问权的攻击者。磁盘与 swap 加密保护关机后的存储，运行期间仍需信任主机和获准访问 agent 的程序。

## 声明式 Wi-Fi

SSID 和密码写入 `system.sops.yaml` 的 `wifi/environment`，公开的 Nix 声明通过变量名引用它们。以下 `home` 是 NetworkManager 中显示的连接别名，可以自行改名，与真实 SSID 无关。

先按主机 `secrets.nix` 中的连接 profile 变量名填写密文：

```yaml
wifi:
  environment: |
    WIFI_HOME_SSID='示例家庭 Wi-Fi'
    WIFI_HOME_PASSWORD='REPLACE_WITH_HOME_PASSWORD'
```

这是 [systemd EnvironmentFile](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#EnvironmentFile=) 格式，单引号内的空格、`$` 和双引号按原样保留。值含单引号时可用双引号包围，并将值内的双引号和反斜杠分别写为 `\"`、`\\`。各变量值保持单行。

对应的 Nix 结构如下，可据此编辑现有 `profiles` 属性集。该文件已有的 `environmentFiles` 绑定会自动提供 `/run/secrets/wifi-environment`：

```nix
networking.networkmanager.ensureProfiles.profiles = {
  home = {
    connection = {
      id = "home";
      uuid = "8ea236c8-54e2-4a15-ad53-d89032c4b3dd";
      type = "wifi";
      autoconnect = true;
    };
    wifi.ssid = "$WIFI_HOME_SSID";
    wifi-security = {
      key-mgmt = "wpa-psk";
      psk = "$WIFI_HOME_PASSWORD";
    };
    ipv4.method = "auto";
    ipv6.method = "auto";
  };
};
```

这里使用 `"$WIFI_HOME_SSID"`，保留 `$变量名` 给运行时替换。示例使用共享密码（`wpa-psk`）连接。添加其他网络时，在密文中增加一对变量，并在 `profiles` 中增加一个独立 UUID 的连接；只填写环境变量不会自动创建 profile。

应用配置时，SOPS 提供环境文件，`NetworkManager-ensure-profiles.service` 将变量替换为实际值，生成 `/run/NetworkManager/system-connections/home.nmconnection`，权限为 root 所有、0600，然后通知 NetworkManager 重新加载。凭据更新会重启这个生成服务。Nix store 中的连接模板只包含变量引用。

运行 `nmcli connection show` 查看已加载连接，`nmcli connection up home` 连接对应网络。声明和加密凭据变化在重新部署配置后生效；日常使用 GUI 或命令行维护连接，见[本机 Wi-Fi](local-state.md#wi-fi)。
