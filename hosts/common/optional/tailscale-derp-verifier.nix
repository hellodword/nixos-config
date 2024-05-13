{ config, pkgs, persistPath, ... }:

let
  WORK_DIR = "/var/lib/tailscale-derp-verifier";
in
{
  sops.secrets."tailscale-derp-verifier.rclone" = {
    sopsFile = ../../${config.networking.hostName}/secrets/tailscale-derp-verifier.rclone;
    format = "binary";
  };

  # sops --input-type binary --output-type binary hosts/r86s/secrets/tailscale-derp-verifier.env
  sops.secrets."tailscale-derp-verifier.env" = {
    sopsFile = ../../${config.networking.hostName}/secrets/tailscale-derp-verifier.env;
    format = "binary";
  };

  systemd.services.tailscale-derp-verifier = {
    enable = true;
    description = "tailscale-derp-verifier";
    path = with pkgs; [ rclone gnugrep jq coreutils gawk tailscale ];
    script = "${pkgs.bash}/bin/bash ${./tailscale-derp-verifier.sh}";
    environment = {
      WORK_DIR = WORK_DIR;
      RCLONE_CONFIG_FILE = config.sops.secrets."tailscale-derp-verifier.rclone".path;
      ENV_FILE = config.sops.secrets."tailscale-derp-verifier.env".path;
    };
    serviceConfig = {
      Type = "oneshot";
    };
  };

  systemd.timers.tailscale-derp-verifier = {
    enable = true;
    description = "tailscale-derp-verifier";
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
