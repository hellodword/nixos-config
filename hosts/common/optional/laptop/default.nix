{ lib, config, inputs, ... }:

{
  imports = [
    ./backup.nix
    ./openvpn.nix
    ./wireguard.nix
    ./packages.nix
    ./firejail.nix
  ] ++
  [
    ../../../common/global
    ../../../common/users/ubuntu
    ../../../common/users/ubuntu/persist.nix

    ../../../common/optional/secureboot.nix
    ../../../common/optional/tmp.nix
    ../../../common/optional/gc.nix

    ../../../common/optional/openssh-server.nix

    ../../../common/optional/ntfs.nix
    ../../../common/optional/vfat.nix
    ../../../common/optional/ext4.nix

    ../../../common/optional/prefer-ipv4.nix
    ../../../common/optional/adguardhome.nix
    ../../../common/optional/v2ray.nix

    ../../../common/optional/docker.nix
    ../../../common/optional/podman.nix

    ../../../common/optional/access-tokens.nix

    ../../../common/optional/auditd.nix
    ../../../common/optional/virtualbox.nix

    ../../../common/optional/wireless.nix
    ../../../common/optional/ntp.nix

    # ../../../common/optional/xrdp.nix
    ../../../common/optional/audio.nix
    ../../../common/optional/brightless.nix

    ../../../common/optional/bark.nix
    ../../../common/optional/apkid.nix

    ../../../common/optional/adb.nix

    ../../../common/optional/ansible.nix

    ../../../common/optional/tailscale.nix

    ../../../common/optional/extra-cli.nix
  ]
  ++
  [
    ../../../common/optional/opengl.nix
    ../../../common/optional/fonts.nix
    ../../../common/optional/sway.nix
    ../../../common/optional/qt.nix
    ../../../common/optional/touchpad.nix
    ../../../common/optional/thermald.nix
    # ../../../common/optional/fwupd.nix
  ];

  environment.etc =
    let
      username = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;
    in
    (builtins.listToAttrs (map
      (x: {
        name = "ssh/${x.path}";
        value = {
          text = x.pub;
          user = username;
          group = config.users.users."${username}".group;
          mode = "0600";
        };
      })
      inputs.nixos-privates.ssh."laptop".keys));
}
