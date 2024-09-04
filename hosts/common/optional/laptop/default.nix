{
  config,
  inputs,
  userName,
  ...
}:

{
  imports =
    [
      ./backup.nix
      ./packages.nix
      ./firejail.nix
    ]
    ++ [
      ../../../common/global
      ../../../common/users/common
      ../../../common/users/common/persist.nix

      ../../../common/optional/secureboot.nix
      ../../../common/optional/tmp.nix
      ../../../common/optional/gc.nix

      ../../../common/optional/openssh-server.nix

      ../../../common/optional/ntfs.nix
      ../../../common/optional/vfat.nix
      ../../../common/optional/ext4.nix

      ../../../common/optional/prefer-ipv4.nix
      ../../../common/optional/sing-box.nix
      ../../../common/optional/adguardhome.nix

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
    ++ [
      ../../../common/optional/opengl.nix
      ../../../common/optional/fonts.nix
      ../../../common/optional/sway.nix
      ../../../common/optional/qt.nix
      ../../../common/optional/touchpad.nix
      ../../../common/optional/thermald.nix
      # ../../../common/optional/fwupd.nix
    ];

  environment.etc = (
    builtins.listToAttrs (
      map (x: {
        name = "ssh/${x.path}";
        value = {
          text = x.pub;
          user = userName;
          group = config.users.users."${userName}".group;
          mode = "0600";
        };
      }) inputs.nixos-privates.ssh."laptop".keys
    )
  );
}
