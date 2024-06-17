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
      # filter regular file only
      dynamicFilesFrom = ''
        echo

        find "${persistPath}/home/${userName}/.gnupg" -type f || true
        find "${persistPath}/home/${userName}/.ssh" -type f || true

        find "${persistPath}/home/${userName}/.config/kdeconnect" -type f || true

        find "${persistPath}/usr/local/etc/sing-box" -type f || true

        if [ -d "${persistPath}/home/${userName}/.config/joplin-desktop" ]; then
          echo "${persistPath}/home/${userName}/.config/joplin-desktop"
        fi

        if [ -d "${persistPath}/home/${userName}/.config/Bitwarden" ]; then
          echo "${persistPath}/home/${userName}/.config/Bitwarden"
        fi

        if [ -d "${persistPath}/etc/secureboot" ]; then
          echo "${persistPath}/etc/secureboot"
        fi

        if [ -d "${persistPath}/etc/xrdp" ]; then
          echo "${persistPath}/etc/xrdp"
        fi

        find "${persistPath}/home/${userName}/.android" -type f -name adbkey* || true

        # find "${persistPath}/home/${userName}/.cache" -type f -name rofi3.druncache || true
      '';
      exclude = [ ];
      paths = [
        "${persistPath}/etc/machine-id"
        "${persistPath}/etc/ssh/ssh_host_*"

        "${persistPath}/home/${userName}/backups/git"
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

  # TODO notify on failure/success

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
