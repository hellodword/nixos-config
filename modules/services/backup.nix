{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.backup;
  notifications = config.site.notifications.enable or false;
  json = pkgs.formats.json { };
  canary = "nixos-config backup recovery canary v1\n";
  canaryPath = "var/lib/site-backup/canary";
  policy = json.generate "backup-policy.json" {
    host = config.networking.hostName;
    roots = cfg.roots ++ [
      {
        path = canaryPath;
        required = true;
      }
    ];
    canary = {
      path = canaryPath;
      sha256 = builtins.hashString "sha256" canary;
    };
    checkPartitions = cfg.checkPartitions;
    minimumIntervalSeconds = {
      backup = 12 * 3600;
      check = 7 * 86400;
      restore-test = 7 * 86400;
      maintenance = 7 * 86400;
    };
    retention = [
      "--keep-daily"
      "7"
      "--keep-weekly"
      "5"
      "--keep-monthly"
      "12"
      "--keep-yearly"
      "75"
    ];
  };
  healthTargets = json.generate "backup-health-targets.json" (
    lib.mapAttrs (_: target: target.repositoryFile) cfg.targets
  );
  operations = [
    "backup"
    "check"
    "restore-test"
    "maintenance"
  ];
  nameFor = target: operation: "site-backup-${target}-${operation}";
  command =
    target: operation:
    let
      state = "/var/lib/site-backup-${target}";
    in
    "${pkgs.python3}/bin/python3 ${../../scripts/backup/runner.py} ${operation} --policy ${policy} --source ${lib.escapeShellArg cfg.source} --state ${state} --restic ${lib.getExe pkgs.restic}"
    + lib.optionalString notifications " --run-state /run/${nameFor target operation}/result.json";
  mkService =
    target: settings: operation:
    lib.nameValuePair (nameFor target operation) {
      description = "Restic ${operation} for independent ${target} repository";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      onSuccess = [ "site-backup-status.service" ];
      onFailure = [ "site-backup-status.service" ];
      unitConfig = {
        ConditionPathIsMountPoint = cfg.source;
        # An hourly timer retries skipped AC-only work. Persistent catches power-off gaps.
        ConditionACPower = lib.mkIf (operation != "backup") true;
      };
      environment = {
        RESTIC_CACHE_DIR = "/var/cache/restic-backups-${config.networking.hostName}-${target}";
        RESTIC_REPOSITORY_FILE = settings.repositoryFile;
        RESTIC_PASSWORD_FILE = settings.passwordFile;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        EnvironmentFile = settings.environmentFile;
        StateDirectory = "site-backup-${target}";
        StateDirectoryMode = "0700";
        CacheDirectory = "restic-backups-${config.networking.hostName}-${target}";
        CacheDirectoryMode = "0700";
        RuntimeDirectory = lib.mkIf notifications (nameFor target operation);
        RuntimeDirectoryMode = "0700";
        ExecStopPost = lib.mkIf notifications (
          "${pkgs.python3}/bin/python3 ${../../scripts/backup}/notify.py"
          + " --host ${lib.escapeShellArg config.networking.hostName} --target ${target} --operation ${operation}"
          + " --state /var/lib/site-backup-${target} --run-state /run/${nameFor target operation}/result.json"
          + " --client /run/current-system/sw/bin/site-notify"
          + lib.concatMapStrings (
            channel: " --channel ${lib.escapeShellArg channel}"
          ) config.site.notifications.backupChannels
        );
        TimeoutStopSec = lib.mkIf notifications (
          toString (100 * builtins.length config.site.notifications.backupChannels + 15)
        );
        UMask = "0077";
        Nice = 15;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
        TimeoutStartSec = "12h";
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep --mode=block --who=Restic --why=Backup ${command target operation}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        PrivateDevices = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        ReadOnlyPaths = [ cfg.source ];
      };
    };
in
{
  imports = [ ../core/storage.nix ];
  options.site.backup = {
    enable = lib.mkEnableOption "independent Restic repositories with verified selection and recovery";
    source = lib.mkOption {
      type = lib.types.str;
      default = config.site.storage.persistRoot;
      description = "Required mounted source filesystem; selected paths are relative to it.";
    };
    roots = lib.mkOption {
      description = "Nonoverlapping roots. Exclusions apply only within their root; optional omissions are recorded in protected status.";
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption { type = lib.types.str; };
            required = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            includePaths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Root-relative file patterns; an empty list selects all files before exclusions.";
            };
            excludeNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            excludePaths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
    };
    checkPartitions = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 12;
      description = "Rotate pack verification across this many weekly partitions; advance only after success.";
    };
    targets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            repositoryFile = lib.mkOption {
              type = lib.types.str;
              description = "Runtime file containing repository URL.";
            };
            passwordFile = lib.mkOption {
              type = lib.types.str;
              description = "Runtime repository password; never a Nix store path.";
            };
            environmentFile = lib.mkOption {
              type = lib.types.str;
              description = "Runtime provider access credentials.";
            };
            minute = lib.mkOption {
              type = lib.types.ints.between 0 59;
              description = "Minute within each hour, staggered across repositories.";
            };
          };
        }
      );
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.targets != { } && cfg.roots != [ ];
        message = "Backup requires explicit paths and at least one repository.";
      }
      {
        assertion = lib.all (name: builtins.match "[a-z0-9-]+" name != null) (
          builtins.attrNames cfg.targets
        );
        message = "Backup target names must be safe unit/path components.";
      }
      {
        assertion = lib.all (
          t:
          lib.all (p: lib.hasPrefix "/" p && !lib.hasPrefix "/nix/store/" p) [
            t.repositoryFile
            t.passwordFile
            t.environmentFile
          ]
        ) (builtins.attrValues cfg.targets);
        message = "Backup credentials and repository locations must be runtime absolute paths outside the store.";
      }
    ];
    environment.etc."backup/policy.json".source = policy;
    environment.systemPackages = [
      pkgs.restic
      (pkgs.writeShellScriptBin "backup-status" ''
        exec ${pkgs.jq}/bin/jq . /run/site-backup/status.json
      '')
    ];
    systemd.tmpfiles.rules = [
      "d ${cfg.source}/var/lib/site-backup 0700 root root -"
      "f ${cfg.source}/${canaryPath} 0600 root root - ${lib.replaceStrings [ "\n" ] [ "\\n" ] canary}"
    ];
    systemd.services =
      (lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (target: settings: map (mkService target settings) operations) cfg.targets
        )
      ))
      // {
        site-backup-status = {
          # Refresh when several independent jobs complete close together.
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RuntimeDirectory = "site-backup";
            RuntimeDirectoryMode = "0755";
            RuntimeDirectoryPreserve = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/backup}/health.py --targets ${healthTargets} --policy ${policy} --source ${lib.escapeShellArg cfg.source} --output /run/site-backup/status.json";
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
          };
        };
      };
    systemd.timers =
      (lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            target: settings:
            map (
              operation:
              lib.nameValuePair (nameFor target operation) {
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnCalendar = "*-*-* *:${lib.fixedWidthString 2 "0" (toString settings.minute)}:00 UTC";
                  OnBootSec = "15m";
                  Persistent = true;
                  RandomizedDelaySec = "5m";
                };
              }
            ) operations
          ) cfg.targets
        )
      ))
      // {
        site-backup-status = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "20m";
            OnUnitActiveSec = "1h";
          };
        };
      };
  };
}
