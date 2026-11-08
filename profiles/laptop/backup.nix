{
  config,
  userName,
  lib,
  ...
}:
let
  home = lib.removePrefix "/" config.users.users.${userName}.home;
  optional = path: { inherit path; };
  electronCache = [
    "Cache"
    "Code Cache"
    "GPUCache"
    "DawnCache"
    "DawnGraphiteCache"
    "DawnWebGPUCache"
    "Crashpad"
    "Shared Dictionary"
  ];
in
{
  site.backup = {
    enable = true;
    source = config.site.storage.persistRoot;
    roots = [
      {
        path = "etc/machine-id";
      }
      {
        path = "etc/ssh";
        includePaths = [
          "ssh_host_*_key"
          "ssh_host_*_key.pub"
        ];
      }
      {
        path = "var/lib/sops-nix";
      }
      {
        path = "etc/secureboot";
      }
      {
        path = "var/lib/site-network";
        excludeNames = [ "mullvad-cache" ];
      }
      {
        path = "${home}/.gnupg";
        excludeNames = [
          "gpg-agent.conf"
          "gpg.conf"
          "scdaemon.conf"
          "random_seed"
        ];
        excludePaths = [ "*.lock" ];
      }
      {
        path = "${home}/.ssh";
        excludeNames = [ "config" ];
      }
      (optional "${home}/.config/Bitwarden/data.json")
      (optional "${home}/.config/Bitwarden CLI/data.json")
      {
        path = "${home}/.config/anytype";
        excludeNames = electronCache ++ [ "logs" ];
      }
    ]
    ++
      map
        (profile: {
          path = "${home}/.config/mozilla/firefox/${profile}";
          includePaths = [
            "cookies.sqlite"
            "cookies.sqlite-wal"
            "logins.json"
            "key4.db"
            "key4.db-wal"
            "containers.json"
            "sessionstore.jsonlz4"
            "sessionstore-backups/*"
            "webappsstore.sqlite"
            "webappsstore.sqlite-wal"
            "storage.sqlite"
            "storage.sqlite-wal"
            "storage/default/*/.metadata-v2"
            "storage/default/*/ls/*"
            "storage/default/*/idb/*"
            "storage/permanent/https*/*.metadata-v2"
            "storage/permanent/https*/ls/*"
            "storage/permanent/https*/idb/*"
          ];
        })
        [
          "default"
          "origin"
        ]
    ++ map optional [
      "${home}/backups/git"
      "${home}/backups/webdav"
      "${home}/.config/kdeconnect"
      "${home}/.local/share/kwalletd"
      "${home}/.config/kwalletrc"
      "${home}/.config/gtk-2.0/gtkrc"
      "${home}/.config/gtk-3.0/settings.ini"
      "${home}/.config/gtk-4.0/settings.ini"
      "${home}/.config/kdeglobals"
      "${home}/.config/kwinrc"
      "${home}/.config/kcminputrc"
      "${home}/.config/plasmashellrc"
      "${home}/.config/plasma-org.kde.plasma.desktop-appletsrc"
      "${home}/.config/plasma-workspace"
      "${home}/.local/share/kscreen"
      "${home}/.config/kwinoutputconfig.json"
      "${home}/.config/kanshi"
      "${home}/.config/autorandr"
      "${home}/.config/fcitx5"
      "${home}/.local/share/fcitx5"
      "${home}/.config/git/local.inc"
      "etc/NetworkManager/system-connections"
      "var/lib/NetworkManager/secret_key"
      "var/lib/tailscale/tailscaled.state"
      "usr/local/etc/sing-box"
      "usr/local/etc/network-policy"
      "${home}/.android/adbkey"
      "${home}/.android/adbkey.pub"
    ];
  };

}
