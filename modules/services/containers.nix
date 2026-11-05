{
  config,
  lib,
  pkgs,
  userName,
  ...
}:
let
  cfg = config.site.containers;
in
{
  options.site.containers = {
    enable = lib.mkEnableOption "container-focused host development";
  };
  config = lib.mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ ];
      };
      daemon.settings = {
        live-restore = true;
        log-driver = "local";
        runtimes.runsc = {
          path = "${pkgs.gvisor}/bin/runsc";
          runtimeArgs = [ "--platform=systrap" ];
        };
      };
    };
    systemd.services.docker.serviceConfig.LimitNOFILE = "infinity";
    users.users.${userName} = {
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
    environment.systemPackages = with pkgs; [
      docker-compose
      dive
    ];
  };
}
