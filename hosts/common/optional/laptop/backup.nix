{ lib, pkgs, config, persistPath, ... }:

let
  username = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;

  # TODO hetzner storage box
  resticS3Providers = [
    /*
      idrive
      https://github.com/restic/restic/pull/4279/files
    */
    "idrive"

    /*
      scaleway
      https://www.scaleway.com/en/docs/tutorials/restic-s3-backup/
      https://status.scaleway.com/uptime/6q1d32x121dx

      1. 创建 project restic https://console.scaleway.com/project 并创建 object storage bucket
      2. 创建 policy restic https://console.scaleway.com/iam/policies 选择 1 中的 project，选择 ObjectStorageObjectsDelete/ObjectStorageObjectsRead/ObjectStorageObjectsWrite/ObjectStorageReadOnly
      3. 创建 application restic https://console.scaleway.com/iam/applications 选择 2 中的 policy restic
      4. 创建 API Keys https://console.scaleway.com/iam/api-keys 选择 3 中的 application restic
    */
    "scaleway"

    /*
      wasabi
      https://status.wasabi.com/uptime/5w7g77w19r8z?page=1

      1. 创建 policy restic https://console.wasabisys.com/policies
      {
          "Version": "2012-10-17",
          "Statement": [
              {
                  "Effect": "Allow",
                  "Action": [
                      "s3:ListBucket",
                      "s3:DeleteObject",
                      "s3:GetObject",
                      "s3:PutObject",
                      "s3:PutObjectAcl"
                  ],
                  "Resource": [
                      "arn:aws:s3:::bucketname",
                      "arn:aws:s3:::bucketname/*"
                  ]
              }
          ]
      }

      2. 创建 User restic https://console.wasabisys.com/users 勾选 Programmatic，创建 group restic，Policy 选择 restic
    */
    "wasabi"

    /*
      Cloudflare R2

      2023-08-16 支持设置 API Key 只对特定 bucket 生效 https://github.com/cloudflare/cloudflare-docs/commit/f4386f52f42359b48c531a1fc47cbc6cfbbcfa35
    */
    "r2"

    /*
      Backblaze B2
      https://www.backblaze.com/docs/cloud-storage-integrate-restic-with-backblaze-b2
    */
    "b2"

    /*
      telnyx
      https://support.telnyx.com/en/articles/8047928-use-dragondisk-with-telnyx-storage
      the secret key is not used by Telnyx Storage, you can type out anything you want here
    */
    "telnyx"
  ];

  mkResticS3 = name:
    let
      cacheDir = "${persistPath}/borgbackup/.restic/${name}";
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
        config.services.borgbackup2.jobs."${config.networking.hostName}".repo
      ];
      pruneOpts = [
        # "--keep-daily 7"
        # "--keep-weekly 5"
        # "--keep-monthly 12"
        # "--keep-yearly 75"
      ];
      timerConfig = {
        OnCalendar = [
          "*-*-* 02:10:00" # 10:10
          "*-*-* 07:10:00" # 15:10
          "*-*-* 13:10:00" # 21:10
        ];
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
      user = "root";
    };

  setResticS3 = cfg: name:
    let
      require = [ "network.target" ]
        ++ lib.optionals config.services.v2raya.enable [ "v2raya.service" ]
        ++ lib.optionals config.services.v2ray.enable [ "v2ray.service" ];
    in
    {
      # requires = lib.mkForce require;
      after = lib.mkForce require;
      # before = [ ]
      #   # (maybe) fix: a stop job is running for dhcp
      #   ++ lib.optionals config.networking.dhcpcd.enable [ "dhcpcd.service" ];
      # preStart = '''';
      # preStop = '''';
    };
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

  # TODO notify on failure

  services.borgbackup2.jobs =
    let
      commonOptions = {
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
        startAt = "hourly";
        persistentTimer = true;
        prune = {
          keep = {
            within = "2d"; # Keep all archives from the last day
            daily = 7;
            weekly = 4;
            monthly = -1; # Keep at least one archive for each month
          };
        };
      };

      commonExclude = [
        "${persistPath}/etc/ssh/gpg.*"
        "${persistPath}/home/${username}/.ssh/config"
        "${persistPath}/home/${username}/.ssh/gpg.*"

        "${persistPath}/home/${username}/.gnupg/gpg-agent.conf"
        "${persistPath}/home/${username}/.gnupg/gpg.conf"
        "${persistPath}/home/${username}/.gnupg/scdaemon.conf"
        "${persistPath}/home/${username}/.gnupg/sshcontrol"
        "${persistPath}/home/${username}/.gnupg/S.*"
      ];
    in
    {
      "${config.networking.hostName}" = commonOptions // {
        repo = "${persistPath}/borgbackup/${config.networking.hostName}";

        exclude = [

        ] ++ commonExclude;

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

          "${persistPath}/home/${username}/.gnupg"

          "${persistPath}/usr/local/etc/v2ray/outbounds.json"

          # firefox cookies
          "${persistPath}/home/${username}/.mozilla/firefox/default/sessionstore-backups"
          # "${persistPath}/home/${username}/.mozilla/firefox/default/cookies.sqlite-wal"
          "${persistPath}/home/${username}/.mozilla/firefox/default/cookies.sqlite"

          "${persistPath}/usr/local/etc/openvpn/client"

          "${persistPath}/home/${username}/.cache/rofi3.druncache"
        ];
      };
    };

  services.restic.backups = (lib.listToAttrs (map (name: lib.nameValuePair "borgbackup-${config.networking.hostName}-${name}" (mkResticS3 name)) resticS3Providers));

  systemd.services = (lib.listToAttrs (map (name: lib.nameValuePair "restic-backups-borgbackup-${config.networking.hostName}-${name}" (setResticS3 name)) resticS3Providers));
}
