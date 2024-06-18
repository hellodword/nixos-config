{ config, pkgs, lib, ... }:

let
  bark = pkgs.writeShellApplication {
    name = "bark";
    runtimeInputs = with pkgs; [ openssl_legacy jq curl coreutils ];
    text = ''
      env BARK_DEVICE_TOKEN="$(cat ${config.sops.secrets."bark-device-token".path})" ${../../../scripts/bark.sh} "$@"
    '';
  };
in
{
  sops.secrets."bark-device-token" = {
    mode = "0440";
    group = "users";
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
    path = "/var/lib/bark/bark-device-token";
  };

  environment.systemPackages = [
    bark
  ];

  systemd.services = {
    "systemd-notify-success@" =
      {
        enable = true;
        path = [ pkgs.bash ];
        environment.SERVICE_ID = "%i";
        serviceConfig.ExecStart = ''${lib.getExe bark} "systemd success" "$SERVICE_ID"'';
      };
    "systemd-notify-failure@" =
      {
        enable = true;
        path = [ pkgs.bash ];
        environment.SERVICE_ID = "%i";
        script = ''
          TEMPFILE=$(mktemp)
          journalctl --no-pager -n10 -b -u "$SERVICE_ID" >> $TEMPFILE || systemctl status --no-pager "$SERVICE_ID" >> $TEMPFILE
          ${lib.getExe bark} "❌ $SERVICE_ID" "$(cat "$TEMPFILE")"
        '';
      };
  };
}
