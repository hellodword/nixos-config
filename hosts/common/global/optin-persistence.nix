# This file defines the "non-hardware dependent" part of opt-in persistence
# It imports impermanence, defines the basic persisted dirs, and ensures each
# users' home persist dir exists and has the right permissions
#
# It works even if / is tmpfs, btrfs snapshot, or even not ephemeral at all.
{ inputs, persistPath, ... }:

{
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ];

  # lsblk & btrfs 会有 bug 不完全显示
  environment.persistence = {
    "${persistPath}" = {
      # 不让这些映射的 mount 出现在文件管理器的侧边栏中
      hideMounts = true;

      files = [
        /*
        t.me/nixos_zhcn/264550
        machine-id 没persist 导致 /var/log/journal 里面每次启动的日志都存着不会自动清理

        https://github.com/systemd/systemd/pull/27330
        */
        "/etc/machine-id"
      ];
      directories = [
        # "/var/backup"
        # "/var/cache"
        # "/var/log" # btmp / lastlog / wtmp
        # "/var/www"

        "/var/lib/systemd"

        # (maybe) fix: a stop job is running for dhcp
        "/var/db/dhcpcd"

        # https://www.freedesktop.org/software/systemd/man/systemd-coredump.html
        "/var/lib/systemd/coredump"

        # https://github.com/nix-community/impermanence/issues/178
        "/var/lib/nixos"

        # "/srv"

        {
          directory = "/etc/nixos";
          user = "1000";
          group = "root";
          mode = "0755";
        }

        {
          directory = "/var/log/journal";
          user = "root";
          group = "systemd-journal";
          mode = "u=rwx,g=rs,o=rx";
        }

        "/var/db/sudo/lectured"

        /*
          # https://github.com/jocelynthode/nixos-config/blob/7a181be17e5f691e457bb49372f091b36777b0b5/modules/base/default.nix#LL120C1-L131C10
          # https://github.com/nix-community/impermanence/issues/93
          {
            directory = "/var/lib/private"; # Used when services use DynamicUser and StateDirectory
            mode = "0700";
          }
          {
            directory = "/var/cache/private"; # Used when services use DynamicUser and CacheDirectory
            mode = "0700";
          }
          {
            directory = "/var/log/private"; # Used when services use DynamicUser and LogDirectory
            mode = "0700";
          }
        */
      ]
      ++ [
        # make timers work across reboots
        # https://github.com/ralismark/nixfiles/blob/d2da77630073b782c03b05e9eb472e3d0483010d/os/ephemeral.nix#L19
        # https://github.com/systemd/systemd/issues/6036#issuecomment-323850368
        # https://unix.stackexchange.com/a/387516
        "/var/lib/systemd/timers"
      ]
      ++ [
        # portablectl
        # https://www.freedesktop.org/software/systemd/man/portablectl.html#Files%20and%20Directories
        "/var/lib/portables"
        "/etc/portables"
        "/usr/local/lib/portables"
        # "/usr/lib/portables"
      ]
      ++ [
        # machinectl systemd-nspawn
        # https://www.freedesktop.org/software/systemd/man/machinectl.html#Files%20and%20Directories
        "/var/lib/machines"
        "/usr/local/lib/machines"
        # "/usr/lib/machines"
      ];
    };
  };
  programs.fuse.userAllowOther = true;

  # system.activationScripts.persistent-dirs.text =
  #   let
  #     mkHomePersist = user: lib.optionalString user.createHome ''
  #       mkdir -p ${persistPath}/${user.home}
  #       chown ${user.name}:${user.group} ${persistPath}/${user.home}
  #       chmod ${user.homeMode} ${persistPath}/${user.home}
  #     '';
  #     users = lib.attrValues config.users.users;
  #   in
  #   lib.concatLines (map mkHomePersist users);
}
