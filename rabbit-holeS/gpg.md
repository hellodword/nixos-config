# gpg

```sh
# 创建主密钥
DISPLAY= gpg2 --expert --full-generate-key
#    (8) RSA (set your own capabilities)
# Your selection? 8

# Current allowed actions: Sign Certify Encrypt
#    (S) Toggle the sign capability
# Your selection? S
# Current allowed actions: Certify Encrypt
#    (E) Toggle the encrypt capability
# Your selection? E
# Current allowed actions: Certify
#    (Q) Finished
# Your selection? Q

# What keysize do you want? (3072) 4096
# Requested keysize is 4096 bits

#       <n>y = key expires in n years
# Key is valid for? (0) 2y

# Real name: alice
# Email address:
# Comment:
# You selected this USER-ID:
#     "alice"

# Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? O


# 创建仅供 A 的子密钥
DISPLAY= gpg2 --expert --edit-key alice
# gpg> addkey

#    (8) RSA (set your own capabilities)
# Your selection? 8

# Current allowed actions: Sign Encrypt
#    (S) Toggle the sign capability
# Your selection? S
# Current allowed actions: Encrypt
#    (E) Toggle the encrypt capability
# Your selection? E
# Current allowed actions:
#    (A) Toggle the authenticate capability
# Your selection? A
# Current allowed actions: Authenticate
#    (Q) Finished
# Your selection? Q

# What keysize do you want? (3072) 4096
# Requested keysize is 4096 bits

# Key is valid for? (0) 1y

# gpg> save


# 创建仅供 S 的子密钥
DISPLAY= gpg2 --expert --edit-key alice
# gpg> addkey

#    (4) RSA (sign only)
# Your selection? 4

# What keysize do you want? (3072) 4096
# Requested keysize is 4096 bits

# Key is valid for? (0) 1y

# gpg> save


# 创建仅供 E 的子密钥
DISPLAY= gpg2 --expert --edit-key alice
# gpg> addkey

#    (6) RSA (encrypt only)
# Your selection? 6

# What keysize do you want? (3072) 4096
# Requested keysize is 4096 bits

# Key is valid for? (0) 1y

# gpg> save


# 添加 uid 否则 GitHub 显示 unverified 邮箱对不上
# gpg> adduid
# Real name: hellodword
# Email address: 46193371+hellodword@users.noreply.github.com
# Comment:
# You selected this USER-ID:
#     "hellodword <46193371+hellodword@users.noreply.github.com>"
# gpg> save


# 列出所有
gpg2 --list-secret-keys
# sec   rsa4096/0xD52F1CEAA87CFBD8 2023-07-27 [C] [expires: 2025-07-26]
#       Key fingerprint = 5FD5 E7B3 5ADB 48A4 FF64  7ED6 D52F 1CEA A87C FBD8
# uid                   [ultimate] hellodword <46193371+hellodword@users.noreply.github.com>
# uid                   [ultimate] alice
# ssb   rsa4096/0x8F455A76A68FC390 2023-07-27 [S] [expires: 2024-07-26]
# ssb   rsa4096/0x76DB9E0C4CC24DAA 2023-07-27 [E] [expires: 2024-07-26]
# ssb   rsa4096/0xF27335A008768136 2023-07-27 [AR] [expires: 2024-07-26]


# 确保是 OpenPGPv4
gpg2 --export-options export-minimal --export alice | gpg2 --list-packets  | grep version


# 导出主密钥的公私钥
gpg2 -a --output alice.gpg.pub --export 0xD52F1CEAA87CFBD8!
gpg2 -a --output alice.gpg --export-secret-key 0xD52F1CEAA87CFBD8!


# # 导出所有子密钥
# gpg2 -a --output alice.subkeys.gpg --export-secret-subkeys alice

# 导出单独的子密钥 (需要带上感叹号，否则会导出所有)
gpg2  -a --output alice.subkey-s.gpg.pub --export 0x8F455A76A68FC390!
gpg2  -a --output alice.subkey-s.gpg --export-secret-subkeys 0x8F455A76A68FC390!
# 导出指定 uid 信息
gpg2  -a --output alice.subkey-s-for-github.gpg.pub --export --export-filter keep-uid="uid=hellodword <46193371+hellodword@users.noreply.github.com>" 0x8F455A76A68FC390!
# 最小化导出
gpg -a --export \
    --output alice.subkey-s-for-github.gpg.pub \
    --export-filter keep-uid="uid=hellodword <46193371+hellodword@users.noreply.github.com>" \
    --export-filter drop-subkey="usage=c" \
    --export-filter drop-subkey="usage=e" \
    --export-filter drop-subkey="usage=s" \
    --export-options export-attributes=no \
    --export-options export-minimal=yes \
    0x8F455A76A68FC390!

ls -alh
#  3429 Jul 27 00:00 alice.gpg
#  5369 Jul 27 00:00 alice.gpg.pub
#   744 Jul 27 10:54 alice.ssh.pub
#  4920 Jul 27 10:30 alice.subkey-a.gpg
#  4932 Jul 27 00:00 alice.subkey-e.gpg
#  5700 Jul 27 00:00 alice.subkey-s.gpg
#  5700 Jul 27 00:00 alice.subkey-s.gpg.pub
# 12293 Jul 27 00:00 alice.subkeys.gpg

# 导入某个子密钥
gpg2 --allow-secret-key-import --import alice.subkey-e.gpg

# 导入主密钥
gpg2 --allow-secret-key-import --import alice.gpg
# 信任主密钥
gpg2 --edit-key alice
# gpg> trust
#   5 = I trust ultimately
# Your decision? 5
# gpg> save


# 导出 ssh 公钥
gpg2 -a --output alice.ssh.pub --export-ssh-key 0xF27335A008768136!

# 导出 ssh 私钥
# https://security.stackexchange.com/a/9635
mkdir -p /tmp/gpg2ssh
chmod 700 /tmp/gpg2ssh
cat ~/.gnupg/gpg.conf > /tmp/gpg2ssh/gpg.conf
cat ~/.gnupg/gpg-agent.conf > /tmp/gpg2ssh/gpg-agent.conf
sudo chmod 777 /tmp/gpg2ssh/gpg*.conf
# 先导入 ssh gpg
gpg2 --homedir /tmp/gpg2ssh --allow-secret-key-import --import alice.subkey-a.gpg
# 再移除密码
DISPLAY= gpg2 --homedir /tmp/gpg2ssh --edit-key alice
# gpg> passwd
# 转换为 SSH 私钥
gpg2 --homedir /tmp/gpg2ssh --export-secret-subkeys 0xF27335A008768136! | openpgp2ssh F27335A008768136 > alice.ssh
rm -rf /tmp/gpg2ssh
# 给 SSH 私钥设置密码
chmod 600 alice.ssh
ssh-keygen -f alice.ssh -p


# 续期
gpg --list-keys
# 注意 expire 信息
gpg --edit-key alice
# gpg> key 1
# gpg> expire
# gpg>  1y
# gpg> save


# 更改指定 key 的 action
gpg --edit-key alice
# gpg> key 7
# gpg> change-usage
# ...
# gpg> save
```

## known issues

### github

- github 无法真正实现 revoke subkey 的操作，同时只能添加 subkeys 中的一个
- github 无法真正实现 expire subkey 的操作，只会给所有该 subkey 签的 commits 的二级菜单里添加一个 expired 图标，但一眼望过去全部是 Verified

### nixos to nixos gpg forwarding

> 远程需要 `gpgconf --create-socketdir`
> 远程要设置 SSH_AUTH_SOCK `export SSH_AUTH_SOCK=/run/user/1000/gnupg/S.gpg-agent.ssh`
> 远程不要运行 gpg-agent 服务
> 远程的 sshd 需要 `StreamLocalBindUnlink=yes`，否则下次连接异常
> 远程如果 ssh 退出时还是没有停止 gpg-agent，那就停止后再连接 `pkill gpg-agent`

```sh
# test
echo "test" | gpg --encrypt -r $KEY_ID > enc
gpg --decrypt enc
```

---

- https://gist.github.com/Integralist/f7e17034800b65b51eb7e9807720025a
- https://fvue.nl/wiki/Gpg:_Best_practices
- https://grimoire.carcano.ch/blog/a-quick-easy-yet-comprehensive-gpg-tutorial/
- https://riseup.net/zh/security/message-security/openpgp/gpg-best-practices
- https://unix.stackexchange.com/questions/748747/what-is-ar-for-gpg-gnupg-authentication-keys
- https://paul.fawkesley.com/gpg-for-humans-why-care-about-cryptography/
- https://paul.fawkesley.com/gpg-for-humans-public-key-crypto-primer/
- https://paul.fawkesley.com/gpg-for-humans-protecting-your-primary-key/
- https://paul.fawkesley.com/gpg-for-humans-preparing-an-offline-machine/
- https://ulyc.github.io/2021/01/13/2021%E5%B9%B4-%E7%94%A8%E6%9B%B4%E7%8E%B0%E4%BB%A3%E7%9A%84%E6%96%B9%E6%B3%95%E4%BD%BF%E7%94%A8PGP-%E4%B8%8A/
- https://github.com/orgs/community/discussions/41199#discussioncomment-5958709
- https://github.com/isaacs/github/issues/1099
- https://gpg.wtf/
- https://unix.stackexchange.com/a/713060
- https://mogeko.me/posts/zh-cn/082/
