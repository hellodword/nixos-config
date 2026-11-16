# 文件服务

长期共享目录是 `~/Downloads/dufs`，普通账号的目录是其中的 `user`。浏览器、WebDAV 和 SMB 操作同一份文件。

| 入口 | 认证与范围 |
| --- | --- |
| `https://<地址>:8443/` | 设备证书验证通过后网页登录；`admin` 可读写全部目录，`user` 可读写 `/user/` |
| `smb://<地址>` | 登录后打开 `files`：`admin` 看到全部目录，`user` 看到自己的目录 |
| `https://<地址>:8444/` | `httpserver` 当前分享的内容，只读，可设置访问码 |

连接使用本机、局域网或 Tailscale 地址；SMB 要求 SMB3 加密。两个 HTTPS 端口使用同一张服务端证书，客户端证书策略分别设置在各自的 TLS 监听点：8443 要求设备身份，8444 不请求客户端证书。因此同一域名或 IP 可以同时用于两个入口。证书 SAN 包含域名和 IP，不包含端口。

在两个端口输入 `http://` 地址，GET 和 HEAD 请求都会跳转到相同主机、实际端口、路径与查询参数的 HTTPS 地址。上传、登录和访问码提交使用 HTTPS。

8443 的网页登录使用安全 Cookie，浏览器保留登录状态，Cookie 在最后访问三十天后过期。服务重启和主机重启保留会话；修改密码并部署后需要重新登录。普通退出清除当前浏览器的登录，账户页也提供退出该账号所有会话的按钮。WebDAV 使用设备证书与同一账号密码；SMB 使用账号密码。

## 配置服务端证书

laptop profile 启用 `site.files`，用主机用户名确定共享目录。部署前，用 SOPS 编辑主机的 `system.sops.yaml`，填写 `files.adminPassword`、`files.userPassword` 和 `files.certificateNames`；完整字段见[凭据示例](../data/secrets/system.example.yaml)。

`certificateNames` 是域名与 IP 数组，加入实际访问的地址即可：

```yaml
files:
  certificateNames:
    - localhost
    - 127.0.0.1
    - "::1"
```

域名通配符写成带引号的 `"*.example.test"`，覆盖该域名下一级子域名。IP 需精确匹配；经常切换网络时可使用稳定的 Tailscale 域名。

地址随 SOPS 加密保存，签发命令从 root 私有的运行时文档读取数组，自动区分域名和 IP。TLS 客户端可以读取服务端证书中的 SAN，服务端证书文件仅 root 可读。

构建并切换系统，重新登录以加载共享组成员身份，再手动签发证书：

```sh
sudo site-files-certificate
```

服务端 CA 保存在 `/var/lib/site-files/ca.crt`，有效期二十年；服务端证书有效期 825 天。地址变更时编辑 SOPS 字段并部署，再运行同一命令；证书到期时直接重新签发。签发复用原 CA 并重启 HTTPS 服务。

## 为设备安装证书

每台设备使用独立身份。设备 CA 有效期二十年，设备证书有效期十年，包含 `clientAuth` 用途。设备 CA 与服务端 CA 分开保存，设备身份通过证书链验证及授权名单后才能使用 8443。

在 laptop 上签发并导出：

```sh
sudo site-files-client issue iphone
sudo site-files-client export iphone --output ./iphone.zip
httpserver --random-code ./iphone.zip
```

`export` 交互询问 P12 密码，ZIP 仅调用用户可读，包含服务端 CA、加密的设备 P12 和 iOS 安装描述文件。描述文件包含同一份加密身份，安装时仍需输入 P12 密码。导出路径必须是新文件。

终端会显示局域网地址、二维码、访问码，以及实际由 8444 提供的服务端证书和服务端 CA 的完整 SHA-256 指纹。

首次访问的顺序如下：

1. 用设备扫描二维码，打开 8444。尚未安装 CA 时浏览器会提示证书不受信任；进入浏览器自身的连接安全详情，选择当前站点的**服务端证书**。
2. 将其完整 SHA-256 指纹与 laptop 终端中 `8444 server certificate` 的值逐项比较。核对的是浏览器实际收到的 TLS 证书；网页正文显示的指纹不能用来确认连接身份。
3. 指纹一致后，在网页输入访问码并下载 ZIP。解压，按下述平台步骤安装。P12 密码只在系统导入身份时输入。
4. 打开 `https://<地址>:8443/`，选择设备身份，再使用 `admin` 或 `user` 登录。
5. 在 laptop 按 Ctrl+C 结束分享，删除两端已用完的导出包和解压文件。

这次人工核对用于防止证书交付过程被中间人替换。比较叶证书时使用终端的 `8444 server certificate` 指纹；安装信任根时使用 `Server CA` 指纹。指纹不一致或浏览器无法显示完整指纹时，先停止输入访问码并核对连接地址。

### iOS 27 / Safari

Safari 网页下方菜单 → **Privacy & Security → Connection Security Details → Details**。在证书链中选站点叶证书，查看 SHA-256，按上面的顺序核对并下载。

在“文件”中解压 ZIP，打开其中的 `.mobileconfig`。到“设置 → 已下载描述文件”完成安装，输入设备解锁密码及导出时设置的 P12 密码。再到“设置 → 通用 → 关于本机 → 证书信任设置”，开启对 `Private file sharing CA` 的完全信任。该描述文件同时安装服务端 CA 与设备身份；单独的 `.p12` 留给其他平台导入。

安装步骤及手动根证书信任见 [Apple 描述文件说明](https://support.apple.com/en-us/102400)和 [Apple 证书信任说明](https://support.apple.com/en-us/102390)。

### Windows / Edge、Chrome

从地址栏的连接信息打开证书查看器，选择站点叶证书并查看 SHA-256；也可用开发者工具的 **Security → View certificate**，[Edge 操作说明](https://learn.microsoft.com/en-us/microsoft-edge/devtools/security/)。

下载并解压后，将 `server-ca.cer` 导入“当前用户 → 受信任的根证书颁发机构”，将设备 `.p12` 导入“当前用户 → 个人”，输入 P12 密码。随后访问 8443 并选择设备证书。

### Android / Chrome

从地址栏连接信息进入证书详情，选择站点叶证书并核对 SHA-256。

下载并解压后，在系统设置的“安全 → 加密与凭据 → 安装证书”中，将 `server-ca.cer` 作为 CA 证书安装，再将设备 `.p12` 作为“VPN 和应用”用户证书安装，输入 P12 密码。不同厂商的菜单名称略有区别；访问 8443 时由 Chrome 调起系统身份选择器。

## 管理设备与状态

```sh
sudo site-files-client list
sudo site-files-client revoke iphone
```

`list` 显示设备名、授权状态、到期时间和 SHA-256。签发和撤销都会更新授权名单并重启 HTTPS 前端，关闭两个端口的已有连接，包括正在进行的临时下载。替换身份时用新名字签发，确认可用后撤销旧身份。

证书、私钥、设备授权、账号与会话状态保存在 `/var/lib/site-files`，随 laptop profile 持久保存并纳入备份。恢复时保留 CA、私钥和授权状态的配套文件，客户端可继续使用原有信任。共享目录沿用 Downloads 的持久化；需要备份的共享资料按[备份范围](backup.md)另行选择。

服务准备共享目录的属主、共享组与组继承权限，网页和 SMB 创建的文件允许本机用户通过共享组读写。本机新建或移入的文件沿用其 Unix 权限；可用 `namei -l ~/Downloads/dufs/user` 检查目录权限。

## 临时分享

```sh
httpserver
httpserver ./report.pdf
httpserver ~/Pictures/trip
httpserver --random-code ./iphone.zip
httpserver --code '自行指定的访问码' ./directory
```

默认分享当前目录；传入文件时，根地址 `https://<地址>:8444/` 直接访问该文件。图片、PDF 和文本按类型显示，文件响应支持 HEAD 和 Range。HTML 与 SVG 在受限的浏览器环境中显示。

命令为活动的局域网网卡地址分别打印 URL 和二维码，包括由实际网卡承载的 bridge 或 VLAN；找不到这样的地址时显示 localhost。每个地址都会检查证书 SAN，缺少的地址仍会显示，并提示添加到 SOPS 的 `files.certificateNames`。将常用地址一次加入数组、部署并重新签发，之后保留该配置即可。

访问码可自行指定或随机生成。它只用于当前分享；浏览器通过验证后持有 Secure、HttpOnly、SameSite=Lax 会话 Cookie。新分享生成新会话，二维码只包含地址。命令在前台显示请求概要，按 Ctrl+C 结束分享及正在传输的文件，一次只能运行一个分享；空闲入口返回 404。

传入路径按实际文件系统位置检查，包括持久目录的 bind mount 别名。整个 home 等宽泛根目录需要改为具体子目录；敏感名称与路径由 [`site.files.temporary`](../modules/services/files.nix) 声明，可在主机配置中追加。目录浏览使用 Nginx 原生列表，普通点文件可通过具体 URL 访问。

临时容器以当前用户身份读取选定路径，只读挂载、禁止符号链接穿透，使用无网络的 gVisor 运行时。HTTPS 前端通过专用 Unix socket 转发请求，只向分享容器转交分享会话，证书私钥留在 HTTPS 服务内。

## 访问与排查

Linux 上从自己的导出包解压 P12 后，可以验证证书并读写文件；curl 会交互询问 P12 密码和账号密码：

```sh
curl --cacert /var/lib/site-files/ca.crt --cert-type P12 --cert ./linux.p12 \
  --user admin --upload-file ./report.pdf https://localhost:8443/user/report.pdf
curl --cacert /var/lib/site-files/ca.crt --cert-type P12 --cert ./linux.p12 \
  --user user https://localhost:8443/user/report.pdf
smbclient //localhost/files -U user --client-protection=encrypt
```

两个 HTTPS 入口持续记录请求，在请求完成后向 journal 写入一条 JSON：

- 时间、入口端口、真实客户端 IP、method、含查询参数的 URL 和解码后的 path。
- 请求与响应的 headers，保留重复字段；内容采用 HAProxy 解析后的形式。
- 未压缩的 `text/*`、JSON、XML、表单等文本请求正文，按原始字节截取前 4096 字节，后续内容继续流式转发。
- 响应状态码、代理统计的收发字节数、总耗时、后端状态与耗时，以及连接结束状态；耗时单位为毫秒。

日志保留 Authorization、Cookie、Set-Cookie、访问码请求头和文本正文中的原值，按凭据资料保管。`httpserver` 终端显示临时分享后端的请求概要，完整记录在 HTTPS 前端的 journal 中。

```sh
sudo journalctl -u site-files-web.service --all -f -o cat
sudo journalctl -u site-files-browser.service -f -o cat
```

请求日志随系统 journal 持久保存和轮转；空闲临时入口的 404 也会记录。服务状态可从 `systemctl status 'site-files-*'` 查看。

Copyparty 通过卷权限区分两个账号，Samba 按认证身份选择共享根目录。文件后端与 HAProxy 前端各有独立的文件系统视图和私有网络空间，主机端口由 systemd 转发；PROXY protocol 保留客户端 IP 与入口端口。访问来源沿用[本地网络策略](network.md)。
