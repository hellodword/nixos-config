{ config, pkgs, ... }:

{
  sops.secrets."bark-device-token" = {
    mode = "0440";
    group = "users";
    sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
    path = "/var/lib/bark/bark-device-token";
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "bark";
      runtimeInputs = with pkgs; [ openssl_legacy jq curl coreutils ];
      text = ''
        env BARK_DEVICE_TOKEN="$(cat ${config.sops.secrets."bark-device-token".path})" ${../../../scripts/bark.sh} "$@"
      '';
    })
  ];
}
