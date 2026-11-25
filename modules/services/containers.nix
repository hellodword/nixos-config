{
  config,
  lib,
  pkgs,
  userName ? null,
  ...
}:
let
  cfg = config.site.containers;
  caches = import ../../nix/cache-config.nix;
  hardening = import ../../lib/service-hardening.nix;
  hasUser = userName != null && userName != "";
  userHome = if hasUser then config.users.users.${userName}.home else "";
  userGroup = if hasUser then config.users.users.${userName}.group else "";
  stateRoot = "${userHome}/.local/state/devcontainers";
  cacheRoot = "${stateRoot}/cache";
  persistRoot = config.site.storage.persistRoot;
  prunePkg = pkgs.writeShellApplication {
    name = "devcontainer-cache-prune";
    runtimeInputs = [
      config.virtualisation.docker.package
      pkgs.python3
    ];
    text = ''
      exec python3 ${../../scripts/containers/prune_caches.py} "$@"
    '';
  };
in
{
  imports = [
    ../core/reserved-ports.nix
    ../network/containers.nix
  ];
  options.site.containers = {
    enable = lib.mkEnableOption "container-focused host development";
    hostStoreCache = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Export the host /nix/store read-only over HTTP to local Docker bridges via Harmonia.";
      };
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = caches.hostStore.listenAddress;
        description = "Container bridge IPv4 address bound by Harmonia.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = caches.hostStore.port;
        description = "TCP port bound by Harmonia on the container bridge.";
      };
      priority = lib.mkOption {
        type = lib.types.ints.positive;
        default = caches.hostStore.priority;
        description = "Binary cache priority advertised in /nix-cache-info.";
      };
    };
    sharedCachePrune = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = hasUser;
        defaultText = lib.literalExpression "userName != null && userName != \"\"";
        description = "Schedule container-isolated reclamation for shared devcontainer caches.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/hellodword/devcontainers-dev:agent";
        description = "Container image providing devcontainer-runtime prune-caches.";
      };
      dates = lib.mkOption {
        type = lib.types.singleLineStr;
        default = "daily";
        description = "systemd calendar schedule for shared devcontainer cache reclamation.";
      };
      randomizedDelaySec = lib.mkOption {
        type = lib.types.singleLineStr;
        default = "30m";
        description = "Randomized delay added before scheduled cache reclamation.";
      };
    };
  };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        virtualisation.docker = {
          enable = true;
          autoPrune = {
            enable = true;
            dates = "weekly";
            flags = [ ];
          };
          daemon.settings = {
            bip = lib.mkDefault "${cfg.hostStoreCache.listenAddress}/16";
            live-restore = true;
            log-driver = "local";
            runtimes.runsc = {
              path = "${pkgs.gvisor}/bin/runsc";
              runtimeArgs = [ "--platform=systrap" ];
            };
          };
        };
        users.users = lib.mkIf hasUser {
          ${userName} = {
            extraGroups = [ "docker" ];
            subUidRanges = [
              {
                startUid = 100000;
                count = 65536;
              }
            ];
            subGidRanges = [
              {
                startGid = 100000;
                count = 65536;
              }
            ];
          };
        };
        environment.systemPackages =
          (with pkgs; [
            docker-compose
            dive
          ])
          ++ lib.optional hasUser prunePkg;
        systemd.tmpfiles.rules = lib.optionals hasUser [
          "d ${userHome}/.local 0700 ${userName} ${userGroup} -"
          "d ${userHome}/.local/state 0700 ${userName} ${userGroup} -"
          "d ${stateRoot} 0700 ${userName} ${userGroup} -"
          "d ${stateRoot}/codex 0700 ${userName} ${userGroup} -"
          "d ${stateRoot}/gemini 0700 ${userName} ${userGroup} -"
          "d ${stateRoot}/opencode 0700 ${userName} ${userGroup} -"
          "d ${cacheRoot} 0700 ${userName} ${userGroup} -"
          "d ${cacheRoot}/nix 0755 ${userName} ${userGroup} -"
          "d ${cacheRoot}/xdg 0700 ${userName} ${userGroup} -"
          "d ${cacheRoot}/cargo 0700 ${userName} ${userGroup} -"
        ];
      }
      (lib.mkIf cfg.hostStoreCache.enable {
        site.reservedPorts = [ cfg.hostStoreCache.port ];
        assertions = [
          {
            assertion = config.nix.settings.require-sigs;
            message = "Host store cache export requires Nix signature verification.";
          }
        ];
        services.harmonia.cache = {
          enable = true;
          settings = {
            bind = "${cfg.hostStoreCache.listenAddress}:${toString cfg.hostStoreCache.port}";
            priority = cfg.hostStoreCache.priority;
          };
        };
        systemd.sockets.harmonia.socketConfig.FreeBind = true;
        systemd.services.harmonia = {
          wantedBy = [ "docker.service" ];
          serviceConfig = {
            inherit (hardening)
              RemoveIPC
              RestrictSUIDSGID
              SystemCallErrorNumber
              ;
            UMask = lib.mkForce hardening.UMask;
            TimeoutStopSec = "10s";
          };
        };
        networking.firewall.interfaces.docker0.allowedTCPPorts = [ cfg.hostStoreCache.port ];
        networking.nftables.tables.site-host-store-cache = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority -20; policy accept;
              iifname != "lo" iifname != "docker0" iifname != "br-*" tcp dport ${toString cfg.hostStoreCache.port} drop
            }
          '';
        };
      })
      (lib.mkIf (cfg.sharedCachePrune.enable && hasUser) {
        systemd.services.site-devcontainer-cache-prune = {
          description = "Prune shared devcontainer caches inside an isolated container";
          requires = [ "docker.service" ];
          after = [
            "docker.service"
            "local-fs.target"
            "systemd-tmpfiles-setup.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            User = userName;
            Group = userGroup;
            SupplementaryGroups = [ "docker" ];
            ExecStart =
              "${prunePkg}/bin/devcontainer-cache-prune"
              + " --cache-root ${lib.escapeShellArg cacheRoot}"
              + lib.optionalString (persistRoot != "") " --persist-root ${lib.escapeShellArg persistRoot}"
              + " --image ${lib.escapeShellArg cfg.sharedCachePrune.image}";
            Nice = 15;
            IOSchedulingClass = "idle";
            CPUWeight = 10;
            IOWeight = 10;
            TimeoutStartSec = "30m";
            TimeoutStopSec = "30s";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            ProtectSystem = "strict";
            TemporaryFileSystem = "${userHome}:ro";
            BindPaths = [ cacheRoot ];
            InaccessiblePaths = lib.optional (persistRoot != "") "-${persistRoot}";
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            UMask = "0077";
          };
        };
        systemd.timers.site-devcontainer-cache-prune = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.sharedCachePrune.dates;
            Persistent = true;
            RandomizedDelaySec = cfg.sharedCachePrune.randomizedDelaySec;
          };
        };
      })
    ]
  );
}
