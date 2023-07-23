{ lib, pkgs, config, persistPath, ... }:

let
  username = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;

  /*
    scaleway
      https://www.scaleway.com/en/docs/tutorials/restic-s3-backup/
      https://status.scaleway.com/uptime/6q1d32x121dx

    1. 创建 project restic https://console.scaleway.com/project
    2. 创建 policy restic https://console.scaleway.com/iam/policies 选择 1 中的 project，选择 ObjectStorageObjectsDelete/ObjectStorageObjectsRead/ObjectStorageObjectsWrite/ObjectStorageReadOnly
    3. 创建 application restic https://console.scaleway.com/iam/applications 选择 2 中的 policy restic
    4. 创建 API Keys https://console.scaleway.com/iam/api-keys 选择 3 中的 application restic
  */


  # https://github.com/restic/restic/pull/4279/files
  # https://www.hetzner.com/storage/storage-box
  # https://telnyx.com/pricing/storage
  mkResticS3 = name:
    let
      cacheDir = "${persistPath}/borgbackup/.restic";
    in
    {
      package = pkgs.restic;
      checkOpts = [
        "--with-cache"
        "--cache-dir=${cacheDir}"
      ];
      extraBackupArgs = [
        "--cache-dir=${cacheDir}"
      ];
      initialize = true;
      passwordFile = config.sops.secrets."restic-password-${name}".path;
      repositoryFile = config.sops.secrets."restic-repo-${name}".path;
      environmentFile = config.sops.secrets."restic-s3-${name}".path;
      paths = [
        config.services.borgbackup.jobs."${config.networking.hostName}".repo
      ];
      pruneOpts = [
        # "--keep-daily 7"
        # "--keep-weekly 5"
        # "--keep-monthly 12"
        # "--keep-yearly 75"
      ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
      user = "root";
    };

  resticS3Providers = [ "idrive" "scaleway" ];
in
{
  environment.systemPackages = with pkgs; [
    rclone
    restic
    borgbackup
  ];

  # sops.secrets."borgbackup" = {
  #   sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
  # };

  # sops.secrets."restic-repo-idrive" = {
  #   sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
  # };

  # sops.secrets."restic-password-idrive" = {
  #   sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml;
  # };

  # sops.secrets."restic-s3-idrive" = {
  #   sopsFile = ../../../${config.networking.hostName}/secrets/restic-s3-idrive;
  #   format = "binary";
  # };

  sops.secrets = (lib.listToAttrs (
    (map (name: lib.nameValuePair "restic-repo-${name}" { sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml; }) resticS3Providers) ++
    (map (name: lib.nameValuePair "restic-password-${name}" { sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml; }) resticS3Providers) ++
    (map (name: lib.nameValuePair "restic-s3-${name}" { sopsFile = ../../../${config.networking.hostName}/secrets/restic-s3-${name}; format = "binary"; }) resticS3Providers) ++
    [ (lib.nameValuePair "borgbackup" { sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml; }) ]
  ));

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

  services.restic.backups = (lib.listToAttrs (map (name: lib.nameValuePair "borgbackup-${config.networking.hostName}-${name}" (mkResticS3 name)) resticS3Providers));
}
