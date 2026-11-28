{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.site.cache;
  caches = import ../../nix/cache-config.nix;
  projectCache = caches.withProject cfg;
  oranc = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.oranc;
  isLoopback = lib.elem cfg.listenAddress [
    "127.0.0.1"
    "::1"
  ];
  isWildcard = lib.elem cfg.listenAddress [
    "0.0.0.0"
    "::"
  ];
  exposeToBridge = config.virtualisation.docker.enable && !isLoopback;
  needsDockerBridge = exposeToBridge && !isWildcard;
in
{
  imports = [ ../core/reserved-ports.nix ];
  options.site.cache = {
    enable = lib.mkEnableOption "signed OCI cache consumption through oranc";
    registry = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io";
      description = "OCI registry hosting the Nix binary cache.";
    };
    repository = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "GHCR owner/repository containing the Nix binary cache.";
    };
    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Independently verified Nix cache signing public key.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Local IP address used by oranc and its Nix clients.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = caches.project.port;
    };
    netrcFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-owned runtime netrc file for Nix to authenticate to the local proxy.";
    };
  };
  config = lib.mkMerge [
    {
      nix.settings = if cfg.enable then projectCache.settings else caches.publicSettings;
    }
    (lib.mkIf cfg.enable {
      site.reservedPorts = [ cfg.port ];
      assertions = [
        {
          assertion = builtins.match "[a-z0-9_.-]+/[a-z0-9_.-]+" cfg.repository != null;
          message = "OCI cache requires an explicit owner/repository.";
        }
        {
          assertion = builtins.match "[^ :]+:[A-Za-z0-9+/]{43}=" cfg.publicKey != null;
          message = "OCI cache requires an independently verified 32-byte signing public key.";
        }
        {
          assertion = config.nix.settings.require-sigs;
          message = "OCI cache may not disable Nix signature verification.";
        }
        {
          assertion =
            cfg.netrcFile == null
            || (lib.hasPrefix "/" cfg.netrcFile && !lib.hasPrefix "/nix/store/" cfg.netrcFile);
          message = "Registry credentials must be runtime files outside the Nix store.";
        }
      ];
      systemd.services.oranc = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ lib.optional needsDockerBridge "docker.service";
        after = [ "network-online.target" ] ++ lib.optional needsDockerBridge "docker.service";
        serviceConfig = import ../../lib/service-hardening.nix // {
          ExecStart = "${oranc}/bin/oranc server --listen ${lib.escapeShellArg projectCache.listen}";
          Restart = "on-failure";
          RestartSec = "2s";
          TimeoutStopSec = "10s";
          MemoryDenyWriteExecute = true;
        };
      };
      networking = lib.mkIf exposeToBridge {
        nftables.enable = true;
        firewall.interfaces.docker0.allowedTCPPorts = [ cfg.port ];
        nftables.tables.site-oci-cache = {
          family = "inet";
          content = ''
            chain input {
              type filter hook input priority -20; policy accept;
              iifname != "lo" iifname != "docker0" iifname != "br-*" tcp dport ${toString cfg.port} drop
            }
          '';
        };
      };
      nix.settings = lib.optionalAttrs (cfg.netrcFile != null) { netrc-file = cfg.netrcFile; };
    })
  ];
}
