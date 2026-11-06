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
    schedule = { inherit (cfg.schedule) timeZone windows; };
    minimumIntervalSeconds = {
      check = 7 * 86400;
      restore-test = 7 * 86400;
      maintenance = 30 * 86400;
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
    "automatic"
    "backup"
    "check"
    "restore-test"
    "maintenance"
  ];
  nameFor = target: operation: "site-backup-${target}-${operation}";
  notifyCommand =
    target:
    "${pkgs.python3}/bin/python3 ${../../scripts/backup}/notify.py deliver"
    + " --host ${lib.escapeShellArg config.networking.hostName} --target ${target}"
    + " --state /var/lib/site-backup-${target} --client /run/current-system/sw/bin/site-notify"
    + lib.concatMapStrings (
      channel: " --channel ${lib.escapeShellArg channel}"
    ) config.site.notifications.backupChannels;
  minutes =
    value:
    let
      parts = map (v: builtins.fromJSON (lib.removePrefix "0" v)) (lib.splitString ":" value);
    in
    builtins.elemAt parts 0 * 60 + builtins.elemAt parts 1;
  pad = value: lib.fixedWidthString 2 "0" (toString value);
  calendar =
    target:
    lib.concatMap (
      window:
      map
        (
          minute:
          "*-*-* ${pad (builtins.div minute 60)}:${pad (lib.mod minute 60)}:00 ${cfg.schedule.timeZone}"
        )
        (
          lib.filter
            (
              minute:
              lib.mod (
                minute - minutes window.start - (cfg.schedule.offsets.${target} or 0)
              ) cfg.schedule.retryMinutes == 0
            )
            (lib.range (minutes window.start + (cfg.schedule.offsets.${target} or 0)) (minutes window.end - 1))
        )
    ) cfg.schedule.windows;
  command =
    target: operation:
    let
      state = "/var/lib/site-backup-${target}";
    in
    "${pkgs.python3}/bin/python3 ${../../scripts/backup/runner.py} ${operation} --policy ${policy} --source ${lib.escapeShellArg cfg.source} --state ${state} --restic ${lib.getExe pkgs.restic}"
    + " --run-state /run/${nameFor target operation}/result.json"
    + " --offset-minutes ${toString (cfg.schedule.offsets.${target} or 0)}";
  mkService =
    target: settings: operation:
    lib.nameValuePair (nameFor target operation) {
      description = "Restic ${operation} for independent ${target} repository";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      onSuccess = [
        "site-backup-status.service"
      ]
      ++ lib.optional notifications "site-backup-${target}-notify.service";
      onFailure = [
        "site-backup-status.service"
      ]
      ++ lib.optional notifications "site-backup-${target}-notify.service";
      unitConfig = {
        ConditionPathIsMountPoint = cfg.source;
        ConditionACPower = lib.mkIf (
          !builtins.elem operation [
            "backup"
            "automatic"
          ]
        ) true;
      };
      environment = {
        RESTIC_CACHE_DIR = "/var/cache/restic-backups-${config.networking.hostName}-${target}";
        RESTIC_REPOSITORY_FILE = settings.repositoryFile;
        RESTIC_PASSWORD_FILE = settings.passwordFile;
        PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
      };
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        EnvironmentFile = settings.environmentFile;
        StateDirectory = "site-backup-${target}";
        StateDirectoryMode = "0700";
        CacheDirectory = "restic-backups-${config.networking.hostName}-${target}";
        CacheDirectoryMode = "0700";
        RuntimeDirectory = nameFor target operation;
        RuntimeDirectoryMode = "0700";
        ExecStopPost = (
          "${pkgs.python3}/bin/python3 ${../../scripts/backup}/notify.py finalize"
          + " --state /var/lib/site-backup-${target} --run-state /run/${nameFor target operation}/result.json"
        );
        TimeoutStopSec = "30s";
        KillMode = "control-group";
        UMask = "0077";
        Nice = 15;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
        IOWeight = 10;
        TimeoutStartSec = "12h";
        ExecStart = command target operation;
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
    schedule = {
      timeZone = lib.mkOption {
        type = lib.types.str;
        default = "Asia/Shanghai";
        description = "Timezone for automatic backup windows, independent of the system timezone.";
      };
      retryMinutes = lib.mkOption {
        type = lib.types.ints.between 1 60;
        default = 15;
      };
      offsets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.ints.between 0 59);
        default = { };
        description = "Minutes after each window starts, keyed by repository alias.";
      };
      windows = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              start = lib.mkOption { type = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]"; };
              end = lib.mkOption { type = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]"; };
              maintenance = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
            };
          }
        );
        default = [
          {
            start = "10:10";
            end = "12:00";
          }
          {
            start = "21:10";
            end = "23:00";
            maintenance = true;
          }
        ];
        description = "Daily local-time windows; end is exclusive. Maintenance also requires AC and this window's successful backup.";
      };
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
      // lib.optionalAttrs notifications (
        lib.mapAttrs' (
          target: _:
          lib.nameValuePair "site-backup-${target}-notify" {
            description = "Deliver latest backup results for ${target}";
            onSuccess = [ "site-backup-status.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = notifyCommand target;
              StateDirectory = "site-backup-${target}";
              StateDirectoryMode = "0700";
              UMask = "0077";
              TimeoutStopSec = "5s";
              TimeoutStartSec = "15m";
              KillMode = "control-group";
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              RestrictAddressFamilies = [ "AF_UNIX" ];
            };
          }
        ) cfg.targets
      )
      // {
        site-backup-status = {
          wantedBy = [ "multi-user.target" ];
          after = [
            "local-fs.target"
            "sops-install-secrets.service"
          ];
          # Refresh when several independent jobs complete close together.
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "oneshot";
            RuntimeDirectory = "site-backup";
            RuntimeDirectoryMode = "0755";
            RuntimeDirectoryPreserve = true;
            StateDirectory = map (target: "site-backup-${target}") (builtins.attrNames cfg.targets);
            StateDirectoryMode = "0700";
            ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/backup}/health.py --targets ${healthTargets} --policy ${policy} --source ${lib.escapeShellArg cfg.source} --output /run/site-backup/status.json";
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
          };
        };
      };
    systemd.timers =
      (lib.mapAttrs' (
        target: _:
        lib.nameValuePair (nameFor target "automatic") {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = calendar target;
            Persistent = true;
            AccuracySec = "1s";
          };
        }
      ) cfg.targets)
      // lib.optionalAttrs notifications (
        lib.mapAttrs' (
          target: _:
          lib.nameValuePair "site-backup-${target}-notify" {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "2m";
              OnUnitActiveSec = "5m";
            };
          }
        ) cfg.targets
      )
      // {
        site-backup-status = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnUnitActiveSec = "1h";
          };
        };
      };
  };
}
