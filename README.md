# nixos-config

## sops

```sh
# # user password
# mkpasswd -m sha-512 -R 1000000

# sops --encrypt --age `age-keygen -y ~/.config/sops/age/keys.txt` /path/to/secrets.yaml > secrets/secrets.yaml

# with .sops.yaml and ~/.config/sops/age/keys.txt
sops secrets/secrets.yaml
```

---

## debug

```sh
nix repl

nix-repl> :lf /path/to/flake
Added 20 variables.

nix-repl> nixosConfigurations.vbox.config.me.allowedUnfreePkg
[ "Oracle_VM_VirtualBox_Extension_Pack" ]
```

---

## hosts

### vbox

> vbox 7.0.8  
> System 勾选 `Enable EFI`

0. 克隆

```sh
export TARGET_HOSTNAME="vbox"

# 设置代理
export HTTP_PROXY=http://192.168.1.2:1081/
export HTTPS_PROXY=$HTTP_PROXY
export http_proxy=$HTTP_PROXY
export https_proxy=$HTTP_PROXY
export CURL_NIX_FLAGS="-x $HTTP_PROXY"

# 或者指向旁路由
route add default gw <gateway ip>

# 修改DNS
echo "nameserver <dns>" > /etc/resolv.conf

mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf

# or it will use /run/user/0, which is by default 10% of the machine RAM
mkdir -p /tmp/tmp
export TMPDIR=/tmp/tmp

nix-shell -p git sbctl gnupg knot-dns

mkdir -p ~/.ssh
vim ~/.ssh/<private key for nix-privates>
sudo chmod 600 ~/.ssh/<private key for nix-privates>
vim ~/.ssh/config
# Host hellodword.github.com
#   IdentitiesOnly yes
#   User hellodword
#   HostName github.com
#   ProxyCommand nc -v -x 192.168.1.2:1080 %h %p
#   IdentityFile ~/.ssh/<private key for nix-privates>
#   PreferredAuthentications publickey

eval `ssh-agent`
ssh-add ~/.ssh/<private key for nix-privates>
ssh -T git@hellodword.github.com

git clone <nixos config> nixos-config
cd nixos-config
```

1. 分区

> 只建议用 uuid 区分磁盘

<details><summary>手动分区</summary>

```sh
# Defining a helper variable to make the following commands shorter.
DISK=/dev/disk/by-id/<thd disk>

# wipe out the old partition information
# # wipefs --all $DISK

# Create partition table
parted $DISK -- mklabel gpt

# Create a /boot as $DISK-part1
parted $DISK -- mkpart ESP fat32 1MiB 512MiB
parted $DISK -- set 1 boot on

# Create a /nix as $DISK-part2
parted $DISK -- mkpart Nix 512MiB 100%

# /boot partition for EFI
sleep 2s; mkfs.fat -F 32 -n boot $DISK-part1

# luks
cryptsetup luksFormat --type=luks2 --label=crypt $DISK-part2
cryptsetup open $DISK-part2 crypt
sleep 2s; mkfs.ext4 -L nix /dev/mapper/crypt

# # /nix partition
# mkfs.ext4 $DISK-part2

# Mount your root file system
mount -t tmpfs none /mnt

# Create directories
mkdir -p /mnt/{boot,nix}

# Mount /boot and /nix
mount $DISK-part1 /mnt/boot
# mount $DISK-part2 /mnt/nix
mount /dev/mapper/crypt /mnt/nix
```

</details>

<details open><summary>自动分区</summary>

```sh
# 不能有换行
vim /tmp/crypt.key
# :set binary
# :set noeol
# :wq

# https://github.com/maxbrunet/dotfiles/blob/2dc3532cfbd4aa20be5b9eba989e24a82f593533/scripts/bootstrap.sh#L32C1-L37
$(nix build --no-link --print-out-paths ".#nixosConfigurations.${TARGET_HOSTNAME}.config.system.build.diskoScript")
```

</details>

2. 生成硬件信息

```sh
nixos-generate-config --root /mnt
```

然后对比 `/mnt/etc/nixos/hardware-configuration.nix` 并修改 nixos config 中新 host 的对应文件

3. 准备文件

```sh
# 从 borg 恢复
mkdir -p /tmp/borg
borg mount /path/to/borg/repo::<...> /tmp/borg
# ...
borg umount /tmp/borg
```

```sh
mkdir -p /mnt/persist/home/ubuntu
chown -R $(id -nu 1000):$(id -ng 1000) /mnt/persist/home/ubuntu

# age key for sops-nix
mkdir -p /mnt/persist/var/lib/sops-nix
vim /mnt/persist/var/lib/sops-nix/keys.txt
chmod 0700 /mnt/persist/var/lib/sops-nix
chmod 600 /mnt/persist/var/lib/sops-nix/keys.txt

mkdir -p /mnt/persist/usr/local/etc/openvpn/client

vim /mnt/persist/usr/local/etc/openvpn/client/goose.ovpn
chmod 600 /mnt/persist/usr/local/etc/openvpn/client/goose.ovpn

vim /mnt/persist/usr/local/etc/openvpn/client/fastestvpn.ovpn
chmod 600 /mnt/persist/usr/local/etc/openvpn/client/fastestvpn.ovpn

chmod 0700 /mnt/persist/usr/local/etc/openvpn/client

mkdir -p /mnt/persist/usr/local/etc/v2ray
# 注意是 json 不是 jsonc，见 ./hosts/common/optional/v2ray.nix
vim /mnt/persist/usr/local/etc/v2ray/outbounds.json

mkdir -p /mnt/persist/etc

# secure boot
# # generate for the first time
# sbctl create-keys
# sbctl enroll-keys --microsoft
cp -r /etc/secureboot /mnt/persist/etc/
mkdir -p /mnt/etc/secureboot
cp -r /mnt/persist/etc/secureboot/* /mnt/etc/secureboot/
```

4. 安装

```sh
nixos-install --no-root-passwd  --flake ".#${TARGET_HOSTNAME}" --root /mnt
```

5. switch & update

```sh
nixos-rebuild --use-remote-sudo switch --flake .#laptop3

# 确定修改后不需要进行网络请求的 switch
# https://discourse.nixos.org/t/rebuild-nixos-offline/3679/9
nixos-rebuild --use-remote-sudo switch --option substitute false --flake .#laptop3

nix flake lock --update-input nixos-privates
```

## laptop3

### Secure Boot

> boot.lanzaboote enable 之后

- BIOS - Security - Secure Boot
  - Secure Boot: Enabled
  - Secure Boot Mode: Custom
  - Key Management - Factory Key Provision: Disabled
  - Reset To Setup Mode

---
