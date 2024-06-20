{ lib, pkgs, config, persistPath, userName, ... }:



# TODO fix \n https://github.com/NixOS/nixpkgs/blob/7eabbc2829806a1fa896b82f674c3e0bd23b9dbc/nixos/modules/services/backup/restic.nix#L363-L365


# TODO add --latest=1 to restic snapshots
# snapshots is expensive https://github.com/NixOS/nixpkgs/blob/7eabbc2829806a1fa896b82f674c3e0bd23b9dbc/nixos/modules/services/backup/restic.nix#L358
# https://github.com/restic/restic/issues/2239#issuecomment-483025297

# TODO check is very expensive without `--with-cache`, but with cache, it's dangerous for data
# so `check --no-cache` per 3 days, and `check --with-cache` for others

let
  withBark = (lib.hasAttr "sops" config && lib.hasAttr "bark-device-token" config.sops.secrets);

  resticS3Providers = [
    "idrive"
    "scaleway"
    # # "wasabi"
    "r2"
    "b2"
    "telnyx"
  ];

  mkResticS3 = name:
    # let
    #   cacheDir = "${persistPath}/restic-cache/${name}";
    # in
    {
      package = pkgs.restic;

      runCheck = lib.mkForce false;
      # checkOpts = [
      #   "--with-cache"
      #   "--cache-dir=${cacheDir}"
      # ];

      pruneOpts = [
        # "--cache-dir=${cacheDir}"
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
        "--keep-yearly 75"
      ];

      extraBackupArgs = [
        # "--cache-dir=${cacheDir}"
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
              pruneScript = pkgs.writeShellApplication {
                name = "exe";
                runtimeInputs = with pkgs; [ restic gawk ];
                excludeShellChecks = [ ];
                text = ''
                  set -e
                  set -x
                  [ -f "$RESTIC_REPOSITORY_FILE" ]
                  key="$(sha256sum < "$RESTIC_REPOSITORY_FILE" | head -1 | awk '{print $1}')"
                  last_check="$(cat "$RESTIC_CACHE_DIR/.last_check.$key" 2>/dev/null || echo "0")"
                  current_time="$(date +%s)"
                  if [ $((current_time - last_check)) -ge "$((60*60*24*7))" ]; then
                    echo "$current_time" | tee "$RESTIC_CACHE_DIR/.last_check.$key"
                    "${resticCmd}" check --no-cache --verbose=2
                  else
                    "${resticCmd}" check --with-cache --cache-dir="$RESTIC_CACHE_DIR"
                  fi
                '';
              };
            in
            {
              after = after;
              preStart = lib.mkAfter ''${resticCmd} unlock ${lib.concatStringsSep " " backup.extraBackupArgs}'';
              onSuccess = lib.optionals withBark [ "systemd-notify-success@%i.service" ];
              onFailure = lib.optionals withBark [ "systemd-notify-failure@%i.service" ];
              serviceConfig.ExecStart = lib.mkAfter [ "${lib.getExe pruneScript}" ];
            }
          )
      )
      resticS3Providers
  ));

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
