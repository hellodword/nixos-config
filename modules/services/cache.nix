{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.site.cache;
  oranc = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.oranc;
in
{
  options.site.cache = {
    enable = lib.mkEnableOption "signed OCI cache consumption through oranc";
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
    port = lib.mkOption {
      type = lib.types.port;
      default = 37515;
    };
    netrcFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-owned runtime netrc file for Nix to authenticate to the local proxy.";
    };
  };
  config = lib.mkIf cfg.enable {
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
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = import ../../lib/service-hardening.nix // {
        ExecStart = "${oranc}/bin/oranc server --listen 127.0.0.1:${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStopSec = "10s";
        MemoryDenyWriteExecute = true;
      };
    };
    nix.settings = {
      substituters = [ "http://127.0.0.1:${toString cfg.port}/ghcr.io/${cfg.repository}" ];
      trusted-public-keys = [ cfg.publicKey ];
      require-sigs = true;
    }
    // lib.optionalAttrs (cfg.netrcFile != null) { netrc-file = cfg.netrcFile; };
  };
}
