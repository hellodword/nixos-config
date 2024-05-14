{ config, pkgs, persistPath, ... }:

let
  WORK_DIR = "/var/lib/tailscale-derp-client-verifier-sync";
in
{
  sops.secrets."tailscale-derp-client-verifier-sync.rclone" = {
    sopsFile = ../../${config.networking.hostName}/secrets/tailscale-derp-client-verifier-sync.rclone;
    format = "binary";
  };

  # sops --input-type binary --output-type binary hosts/r86s/secrets/tailscale-derp-client-verifier-sync.env
  sops.secrets."tailscale-derp-client-verifier-sync.env" = {
    sopsFile = ../../${config.networking.hostName}/secrets/tailscale-derp-client-verifier-sync.env;
    format = "binary";
  };

  systemd.services.tailscale-derp-client-verifier-sync = {
    enable = true;
    description = "tailscale-derp-client-verifier-sync";
    path = with pkgs; [ rclone gnugrep jq coreutils gawk tailscale ];
    script = "${pkgs.bash}/bin/bash ${./tailscale-derp-client-verifier-sync.sh}";
    environment = {
      WORK_DIR = WORK_DIR;
      RCLONE_CONFIG_FILE = config.sops.secrets."tailscale-derp-client-verifier-sync.rclone".path;
      ENV_FILE = config.sops.secrets."tailscale-derp-client-verifier-sync.env".path;
    };
    serviceConfig = {
      Type = "oneshot";
    };
  };

  systemd.timers.tailscale-derp-client-verifier-sync = {
    enable = true;
    description = "tailscale-derp-client-verifier-sync";
    after = [ "tailscaled.service" ];
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnUnitInactiveSec = 60 * 3;
      OnBootSec = 30;
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      WORK_DIR
    ];
  };
}
