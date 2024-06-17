{ lib, pkgs, config, persistPath, userName, ... }:

let
  resticS3Providers = [
    # "idrive"
    "scaleway"
    # # "wasabi"
    "r2"
    "b2"
    # "telnyx"
  ];

  mkResticS3 = name:
    let
      cacheDir = "${persistPath}/restic-cache/${name}";
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
      passwordFile = config.sops.secrets."restic-password".path;
      repositoryFile = config.sops.secrets."restic-repo-${name}".path;
      environmentFile = config.sops.secrets."restic-s3-${name}".path;
      # dynamicFilesFrom = ''find /home/matt/git -type d -name .git'';
      exclude = [ ];
      paths = [

        "${persistPath}/etc/machine-id"
        "${persistPath}/etc/ssh/ssh_host_*"

        /*
          ## note
          ### joplin
        */
        "${persistPath}/home/${userName}/.config/joplin-desktop"
        /*
          ## password manager
          ### bitwarden-desktop
        */
        "${persistPath}/home/${userName}/.config/Bitwarden"
      ]
      ++ (lib.optionals (builtins.hasAttr "lanzaboote" config.boot && config.boot.lanzaboote.enable) [
        "${persistPath}/etc/secureboot"
      ])
      ++ (lib.optionals config.services.xrdp.enable [
        "${persistPath}/etc/xrdp"
      ])
        # ++ (lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [
        #   "${persistPath}/usr/local/etc/sing-box/*.json"
        # ])
      ;
      pruneOpts = [
        # "--keep-daily 7"
        # "--keep-weekly 5"
        # "--keep-monthly 12"
        # "--keep-yearly 75"
      ];
      timerConfig = {
        OnCalendar = [
          "*-*-* 02:10:00" # 10:10
          # "*-*-* 07:10:00" # 15:10
          "*-*-* 13:10:00" # 21:10
        ];
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
      user = "root";
    };
in
{
  environment.systemPackages = with pkgs; [
    rclone
    restic
  ];

  sops.secrets = (lib.listToAttrs (
    (map (name: lib.nameValuePair "restic-repo-${name}" { sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml; }) resticS3Providers) ++
    (map (name: lib.nameValuePair "restic-s3-${name}" { sopsFile = ../../../${config.networking.hostName}/secrets/restic-s3-${name}; format = "binary"; }) resticS3Providers) ++
    [ (lib.nameValuePair "restic-password" { sopsFile = ../../../${config.networking.hostName}/secrets/secrets.yaml; }) ]
  ));

  # TODO notify on failure

  # services.borgbackup2.jobs =
  #   let
  #     commonOptions = {
  #       appendFailedSuffix = true;
  #       compression = "auto,zstd,3";
  #       doInit = true;
  #       encryption = {
  #         mode = "repokey";
  #         passCommand = "cat ${config.sops.secrets."borgbackup".path}";
  #       };

  #       # environment = {
  #       #   BORG_RSH = "ssh -i /path/to/key";
  #       # };
  #       user = "root";
  #       group = "root";
  #       startAt = "hourly";
  #       persistentTimer = true;
  #       prune = {
  #         keep = {
  #           within = "2d"; # Keep all archives from the last day
  #           daily = 7;
  #           weekly = 4;
  #           monthly = -1; # Keep at least one archive for each month
  #         };
  #       };
  #     };

  #     commonExclude = [
  #       "${persistPath}/etc/ssh/gpg.*"
  #       "${persistPath}/home/${userName}/.ssh/config"
  #       "${persistPath}/home/${userName}/.ssh/gpg.*"

  #       "${persistPath}/home/${userName}/.gnupg/gpg-agent.conf"
  #       "${persistPath}/home/${userName}/.gnupg/gpg.conf"
  #       "${persistPath}/home/${userName}/.gnupg/scdaemon.conf"
  #       "${persistPath}/home/${userName}/.gnupg/sshcontrol"
  #       "${persistPath}/home/${userName}/.gnupg/S.*"
  #     ];
  #   in
  #   {
  #     "${config.networking.hostName}" = commonOptions // {
  #       repo = "${persistPath}/borgbackup/${config.networking.hostName}";

  #       exclude = [

  #       ] ++ commonExclude;

  #       paths = [
  #         "${persistPath}/etc"

  #         "${persistPath}/home/${userName}/.ssh"
  #         "${persistPath}/home/${userName}/.bash_history"

  #         "${persistPath}/home/${userName}/.config/kdeconnect"
  #         "${persistPath}/home/${userName}/.config/joplin-desktop"
  #         "${persistPath}/home/${userName}/.config/Bitwarden"

  #         "${persistPath}/home/${userName}/.android/adbkey"
  #         "${persistPath}/home/${userName}/.android/adbkey.pub"

  #         "${persistPath}/home/${userName}/backups/borged"

  #         "${persistPath}/home/${userName}/.gnupg"

  #         # firefox cookies
  #         "${persistPath}/home/${userName}/.mozilla/firefox/default/sessionstore-backups"
  #         # "${persistPath}/home/${userName}/.mozilla/firefox/default/cookies.sqlite-wal"
  #         "${persistPath}/home/${userName}/.mozilla/firefox/default/cookies.sqlite"

  #         "${persistPath}/home/${userName}/.cache/rofi3.druncache"
  #       ]
  #       ++ lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [
  #         "/usr/local/etc/sing-box/outbounds.json"
  #         "/usr/local/etc/sing-box/rules.json"
  #       ];
  #     };
  #   };

  services.restic.backups = (lib.listToAttrs (map (name: lib.nameValuePair "${config.networking.hostName}-${name}" (mkResticS3 name)) resticS3Providers));

  systemd.services = (lib.listToAttrs (
    map
      (name:
        lib.nameValuePair
          "restic-backups-${config.networking.hostName}-${name}"
          (
            let
              after = [ "network.target" ]
                ++ lib.optionals (builtins.hasAttr "sing-box" config.systemd.services) [ "sing-box.service" ];
              backup = config.services.restic.backups."${config.networking.hostName}-${name}";
              extraOptions = lib.concatMapStrings (arg: " -o ${arg}") backup.extraOptions;
              resticCmd = "${backup.package}/bin/restic${extraOptions}";
            in
            {
              after = after;
              preStart = lib.mkAfter ''${resticCmd} unlock ${lib.concatStringsSep " " backup.extraBackupArgs}'';
            }
          )
      )
      resticS3Providers
  ));

  # systemd.timers = (lib.listToAttrs (
  #   lib.imap
  #     (index: name:
  #       lib.nameValuePair
  #         "restic-backups-${config.networking.hostName}-${name}"
  #         (
  #           let
  #             prev = lib.optionals (index > 1) [
  #               "restic-backups-${config.networking.hostName}-${(builtins.elemAt resticS3Providers (index - 2))}.timer"
  #             ];
  #           in
  #           {
  #             after = prev;
  #             requires = prev;
  #           }
  #         )
  #     )
  #     resticS3Providers
  # ));


  environment.persistence = {
    "${persistPath}".directories = (map
      (name: {
        directory = "/var/cache/restic-backups-laptop2-${name}";
        user = "root";
        group = "root";
        mode = "0700";
      })
      resticS3Providers) ++ [
      # {
      #   directory = "/root/.cache/borg";
      #   user = "root";
      #   group = "root";
      #   mode = "0755";
      # }
    ];
  };
}
