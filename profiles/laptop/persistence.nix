{
  config,
  lib,
  userName,
  ...
}:
let
  kdeFiles = [
    ".config/kwalletrc"
    ".config/kdeglobals"
    ".config/kwinrc"
    ".config/kcminputrc"
    ".config/kwinoutputconfig.json"
    ".config/plasmashellrc"
    ".config/plasma-org.kde.plasma.desktop-appletsrc"
  ];
in
{
  # State remains accessible when a capability is disabled. Keep the account
  # owning sing-box's state for the same lifetime as its persistent directory.
  users.users.sing-box = {
    isSystemUser = true;
    group = "sing-box";
  };
  users.groups.sing-box = { };
  users.users.${userName}.homeMode = "0700";
  systemd.tmpfiles.rules = map (
    file:
    "f ${config.site.storage.persistRoot}${
      config.users.users.${userName}.home
    }/${file} 0600 ${userName} users -"
  ) kdeFiles;
  environment.persistence.${config.site.storage.persistRoot} = {
    hideMounts = true;
    files = [
      "/etc/machine-id"
    ]
    ++ lib.concatMap (key: [
      key.path
      "${key.path}.pub"
    ]) config.services.openssh.hostKeys;
    directories = [
      "/var/lib/systemd"
      "/var/lib/nixos"
      {
        directory = "/var/cache/nix";
        mode = "1777";
      }
      {
        directory = "/var/log/journal";
        group = "systemd-journal";
        mode = "2755";
      }
      {
        directory = "/etc/nixos";
        user = userName;
        group = "root";
        mode = "0755";
      }
      {
        directory = "/var/lib/sops-nix";
        mode = "0700";
      }
      "/var/lib/sddm"
      "/var/lib/docker"
      "/var/lib/waydroid"
      {
        directory = "/etc/NetworkManager/system-connections";
        mode = "0700";
      }
      {
        directory = "/var/lib/NetworkManager";
        mode = "0700";
      }
      "/usr/local/etc/sing-box"
      "/usr/local/etc/network-policy"
      {
        directory = "/var/lib/site-network";
        mode = "0700";
      }
      {
        directory = "/var/lib/site-network-rules";
        mode = "0700";
      }
      {
        directory = "/var/lib/tailscale";
        mode = "0700";
      }
      "/var/log/mullvad-vpn"
      "/var/lib/logrotate"
      {
        directory = "/var/lib/sing-box";
        user = "sing-box";
        group = "sing-box";
        mode = "0700";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (name: _: [
        {
          directory = "/var/lib/site-backup-${name}";
          mode = "0700";
        }
        {
          directory = "/var/cache/restic-backups-${config.networking.hostName}-${name}";
          mode = "0700";
        }
      ]) (config.site.backup.targets or { })
    );
    users.${userName} = {
      directories = [
        "dev/park"
        "dev/workspace"
        "dev/playground"
        "dev/note"
        "backups"
        "share"
        "go"
        ".docker"
        ".codex"
        ".agents-viewer"
        ".cache/nix-index"
        "Desktop"
        "Documents"
        "Downloads"
        "Music"
        "Pictures"
        "Videos"
        ".local/state"
        ".local/share/nix"
        ".local/share/zoxide"
        ".config/nife"
        {
          directory = ".gnupg";
          mode = "0700";
        }
        {
          directory = ".ssh";
          mode = "0700";
        }
        ".config/git"
        ".config/mozilla/firefox"
        ".cache/mozilla/firefox"
        ".config/google-chrome"
        ".config/Bitwarden"
        ".config/Bitwarden CLI"
        ".config/kdeconnect"
        ".config/Code"
        ".vscode"
        ".vscode-shared"
        ".cache/vscode-cpptools"
        ".config/gtk-2.0"
        ".config/gtk-3.0"
        ".config/gtk-4.0"
        ".config/fcitx5"
        ".local/share/fcitx5"
        ".local/share/kwalletd"
        ".config/plasma-workspace"
        ".local/share/kscreen"
        ".config/kanshi"
        ".config/autorandr"
        ".config/VirtualBox"
        "VirtualBox VMs"
        ".local/share/waydroid"
        ".android"
        ".config/anytype"
        ".config/blender"
        ".config/libreoffice"
        ".config/remmina"
        ".local/share/remmina"
        ".config/freerdp"
        ".config/safeeyes"
      ];
      files = [
        ".bash_history"
        ".cache/rofi3.druncache"
      ]
      ++ map (file: {
        inherit file;
        # KConfig resolves the link before replacing a file atomically.
        method = "symlink";
      }) kdeFiles;
    };
  };
}
