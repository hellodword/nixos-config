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

nix-repl> nixosConfigurations.vbox.config.allowedUnfreePkg
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

mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf

# or it will use /run/user/0, which is by default 10% of the machine RAM
mkdir -p /tmp/tmp
export TMPDIR=/tmp/tmp

nix-shell -p git sbctl

mkdir -p ~/.ssh
vim ~/.ssh/<private key for nix-privates>
vim ~/.ssh/config
# Host hellodword.github.com
#   IdentitiesOnly yes
#   User hellodword
#   HostName github.com
#   ProxyCommand nc -v -x 192.168.1.2:1080 %h %p
#   IdentityFile ~/.ssh/<private key for nix-privates>
#   PreferredAuthentications publickey

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
mkdir -p /mnt/persist/home/ubuntu
chown -R $(id -nu 1000):$(id -ng 1000) /mnt/persist/home/ubuntu

# sudo -u $(id -nu 1000) -g $(id -ng 1000) mkdir -p /mnt/persist/home/ubuntu/.ssh
# sudo -u $(id -nu 1000) -g $(id -ng 1000) vim /mnt/persist/home/ubuntu/.ssh/authorized_keys
# chmod 600 /mnt/persist/home/ubuntu/.ssh/authorized_keys

# age key for sops-nix
mkdir -p /mnt/persist/var/lib/sops-nix
vim /mnt/persist/var/lib/sops-nix/keys.txt
chmod 0700 /mnt/persist/var/lib/sops-nix
chmod 600 /mnt/persist/var/lib/sops-nix/keys.txt

# sudo -u $(id -nu 1000) -g $(id -ng 1000) mkdir -p /mnt/persist/home/ubuntu/.config/sops/age/
# sudo -u $(id -nu 1000) -g $(id -ng 1000) vim /mnt/persist/home/ubuntu/.config/sops/age/keys_home_manager.txt

mkdir -p /mnt/persist/usr/local/etc/adguard-home
curl --output /mnt/persist/usr/local/etc/adguard-home/whitelist_full_combine.txt \
    https://fastly.jsdelivr.net/gh/hellodword/you-know-who@assets/adguard-home/whitelist_full_combine.txt

mkdir -p /mnt/persist/usr/local/etc/openvpn/client

vim /mnt/persist/usr/local/etc/openvpn/client/goose.ovpn
chmod 600 /mnt/persist/usr/local/etc/openvpn/client/goose.ovpn

vim /mnt/persist/usr/local/etc/openvpn/client/fastestvpn.ovpn
chmod 600 /mnt/persist/usr/local/etc/openvpn/client/fastestvpn.ovpn

chmod 0700 /mnt/persist/usr/local/etc/openvpn/client

mkdir -p /mnt/persist/usr/local/etc/v2ray
vim /mnt/persist/usr/local/etc/v2ray/v2ray.jsonc

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

5. switch

```sh
nixos-rebuild --use-remote-sudo switch --flake .#laptop3
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

## TODO

### minimal

- https://github.com/NixOS/nixpkgs/issues/21315
- https://github.com/vikanezrimaya/nixos-super-minimal
- https://github.com/nix-community/NixNG

### router

- https://github.com/disassembler/network/blob/453af8f8467a04a6a9b31dbaa21e8961c7dd32b6/nixos/portal/configuration.nix
- https://nixos.wiki/wiki/Workgroup:Router

### disable binary cache

- https://github.com/NixOS/nixpkgs/issues/20542
- https://musteresel.github.io/posts/2018/05/nix-disable-binary-cache.html

### offline install

- `nix copy`
- https://github.com/tfc/nixos-offline-installer
- https://www.reddit.com/r/NixOS/comments/10dobnn/comment/j4mfvu2

### kernel

```nix
boot.kernelPackages =
  let
    linux_6_4_pkg = { fetchurl, buildLinux, ... } @ args:
      buildLinux (args // rec {
        version = "6.4.0-rc5";
        modDirVersion = version;
        src = fetchurl {
          url = "https://github.com/torvalds/linux/archive/refs/tags/v6.4-rc5.tar.gz";
          sha256 = "sha256-jtPUALgoUhfaldP2tTWQGiR6jKyKkQ9QqXY9eOvntcY=";
        };
        kernelPatches = [
          pkgs.kernelPatches.bridge_stp_helper
          pkgs.kernelPatches.request_key_helper
        ];
        extraMeta.branch = "6.4";
      } // (args.argsOverride or { }));
    linux_6_4 = pkgs.callPackage linux_6_4_pkg { };
  in
  pkgs.recurseIntoAttrs (pkgs.linuxPackagesFor linux_6_4);
```

### hardening

#### SELinux

- https://nixos.wiki/wiki/Workgroup:SELinux
- https://github.com/bqv/rc/blob/7fb53a24e416142e1909e87d19727b6ef4f43236/profiles/security/selinux/default.nix
- https://github.com/MatthewCroughan/nixcfg/blob/a054e7b2d16b0f7e7b26c51c6bfc9e13d5654fa3/examples/other/selinux.nix
- https://github.com/NixOS/nix/pull/2670#issuecomment-1346175168

### backup (module)

---

- https://github.com/Misterio77/nix-config/tree/7278ec9eb9e5bd472b771041d1b494bc9bc188c7
- https://github.com/Misterio77/nix-starter-configs/tree/691c6579c78d770a7cb67b48119fa3fedef9e363
- https://github.com/NickCao/flakes/tree/8c6a74ae4db694cfef3bb6d195655af8f7c9d91f
- https://github.com/figsoda/cfg/tree/fd065f51aa61689ff85554497f3dba952cb1a9f2
- https://github.com/figsoda/pkgs/tree/e9f238013f6b17d2e2b4d31294077bca49d71a89
- https://farseerfc.me/zhs/in-defence-of-swap.html#id17
