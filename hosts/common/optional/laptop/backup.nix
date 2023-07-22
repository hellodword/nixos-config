{ lib, config, persistPath, ... }:

let
  username = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;
in
{
  sops.secrets."borgbackup" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
  };

  # system.activationScripts.make-borgbackup-base-public.text = ''
  #   mkdir -p "${persistPath}/borgbackup"
  #   chown 1000 "${persistPath}/borgbackup"
  # '';

  services.borgbackup.jobs."${config.networking.hostName}" = {
    repo = "${persistPath}/borgbackup/${config.networking.hostName}";
    appendFailedSuffix = true;
    compression = "auto,zstd,3";
    doInit = true;
    encryption = {
      mode = "repokey";
      passCommand = "cat ${config.sops.secrets."borgbackup".path}";
    };
    # environment = {
    #   BORG_RSH = "ssh -i /path/to/key";
    # };
    user = "root";
    group = "root";
    startAt = "daily";
    prune = {
      keep = {
        within = "2d"; # Keep all archives from the last day
        daily = 7;
        weekly = 4;
        monthly = -1; # Keep at least one archive for each month
      };
    };

    exclude = [
      "${persistPath}/home/${username}/.ssh/config"
    ];
    paths = [
      "${persistPath}/etc"

      "${persistPath}/home/${username}/.ssh"
      "${persistPath}/home/${username}/.bash_history"

      "${persistPath}/home/${username}/.config/kdeconnect"
      "${persistPath}/home/${username}/.config/joplin-desktop"
      "${persistPath}/home/${username}/.config/Bitwarden"

      "${persistPath}/home/${username}/.android/adbkey"
      "${persistPath}/home/${username}/.android/adbkey.pub"

      "${persistPath}/home/${username}/backups/borged"
    ];
  };
}
