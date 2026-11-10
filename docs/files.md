# 文件服务

长期共享目录是 `~/Downloads/dufs`，访客目录是其中的 `guest`。浏览器、WebDAV 和 SMB 操作同一份文件。

| 入口 | 账号与范围 |
| --- | --- |
| `https://<地址>:8443/` | `admin` 可读写全部目录；`guest` 可读写 `/guest/` |
| `smb://<地址>/files` | `admin` |
| `smb://<地址>/guest` | `admin`、`guest` |
| `https://<地址>:8444/` | `httpserver` 当前分享的内容，匿名只读 |

连接使用本机、局域网或 Tailscale 地址；SMB 要求 SMB3 加密。HTTPS 地址必须包含在证书 SAN 中，客户端需信任下面生成的 CA。

## 首次配置

laptop profile 启用 `site.files`，用主机用户名确定共享目录。部署前，用 SOPS 编辑主机的 `system.sops.yaml`，填写 `files.adminPassword`、`files.guestPassword` 和 `files.certificateNames`；完整字段见[凭据示例](../data/secrets/system.example.yaml)。

`certificateNames` 是域名与 IP 数组，加入实际访问的地址即可：

```yaml
files:
  certificateNames:
    - localhost
    - 127.0.0.1
    - "::1"
```

域名通配符写成带引号的 `"*.example.test"`，覆盖该域名下一级子域名。IP 需精确匹配；经常切换网络时可使用稳定的 Tailscale 域名。

地址随 SOPS 加密保存，签发命令从 root 私有的运行时文档读取数组，自动区分域名和 IP。TLS 客户端可以读取服务端证书中的 SAN，服务端证书文件仅 root 可读。签发结果显示 CA 路径和有效期。

构建并切换系统，重新登录以加载共享组成员身份，再手动签发证书：

```sh
sudo site-files-certificate
```

将 `/var/lib/site-files/ca.crt` 安装为客户端信任的 CA。CA 有效期为二十年，服务端证书为 825 天。地址变更时编辑 SOPS 字段并部署，再运行同一命令；证书到期时直接重新签发。签发命令复用原 CA 并重启 HTTPS 服务。

证书、私钥和 Samba 身份状态保存在 `/var/lib/site-files`，随 laptop profile 持久保存并纳入备份。恢复时保留原 CA 与其私钥配对，客户端便可继续使用原有信任。共享目录沿用 Downloads 的持久化；需要备份的共享资料按[备份范围](backup.md)另行选择。

新目录设置组继承，服务创建的文件允许本机用户通过共享组读写。本机新建或移入的文件沿用其 Unix 权限；可用 `namei -l ~/Downloads/dufs/guest` 检查目录权限。

## 临时分享

```sh
httpserver
httpserver ./report.pdf
httpserver ~/Pictures/trip
```

命令在前台显示分享路径和 URL，按 Ctrl+C 结束分享及正在传输的文件。一次只能运行一个分享；传入文件时只分享该文件。空闲的 HTTPS 入口返回 404。

传入路径按实际文件系统位置检查，包括持久目录的 bind mount 别名。整个 home 等宽泛根目录需要改为具体子目录；敏感名称与路径由 [`site.files.temporary`](../modules/services/files.nix) 声明，可在主机配置中追加。目录浏览使用 Nginx 原生列表，普通点文件可通过具体 URL 访问。

临时容器以当前用户身份读取选定路径，只读挂载、禁止符号链接穿透，使用无网络的 gVisor 运行时。Nginx 通过专用 Unix socket 转发请求，证书私钥留在 HTTPS 服务内。

## 访问与排查

Linux 上可以验证证书并读写文件：

```sh
curl --cacert /var/lib/site-files/ca.crt --user admin \
  --upload-file ./report.pdf https://localhost:8443/guest/report.pdf
curl --cacert /var/lib/site-files/ca.crt --user guest \
  https://localhost:8443/guest/report.pdf
smbclient //localhost/guest -U guest --client-protection=encrypt
```

服务状态与错误可从 `systemctl status 'site-files-*'` 和 `journalctl -u 'site-files-*'` 查看。管理员与访客使用独立的 Dufs 实例，访客实例只挂载 `guest` 目录。文件后端与 HTTPS 服务各有独立的文件系统视图和私有网络空间，主机端口由 systemd 转发，访问来源沿用[本地网络策略](network.md)。
