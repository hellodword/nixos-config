{ config, persistPath, ... }:

{
  sops.secrets."borgbackup" = {
    sopsFile = ./secrets/secrets.yaml;
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
      "${persistPath}/home/ubuntu/.ssh/config"
    ];
    paths = [
      "${persistPath}/etc"

      "${persistPath}/home/ubuntu/.ssh"
      "${persistPath}/home/ubuntu/.bash_history"

      "${persistPath}/home/ubuntu/.config/kdeconnect"
      "${persistPath}/home/ubuntu/.config/joplin-desktop"
      "${persistPath}/home/ubuntu/.config/Bitwarden"

      "${persistPath}/home/ubuntu/.android/adbkey"
      "${persistPath}/home/ubuntu/.android/adbkey.pub"
    ];
  };
}
