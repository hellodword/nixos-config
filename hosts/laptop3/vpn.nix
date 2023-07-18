{ config, persistPath, ... }:

{
  environment.persistence = {
    "${persistPath}".directories = [
      "/usr/local/etc/openvpn/client"
    ];
  };

  sops.secrets."goose.auth" = {
    sopsFile = ./secrets/goose.auth;
    format = "binary";
  };

  ovpn.servers."goose" = {
    table = 51821;
    auth = "${config.sops.secrets."goose.auth".path}";
    extraConfig = "/usr/local/etc/openvpn/client/goose.ovpn";
  };

  sops.secrets."fastestvpn.auth" = {
    sopsFile = ./secrets/fastestvpn.auth;
    format = "binary";
  };

  ovpn.servers."fastestvpn" = {
    table = 51822;
    auth = "${config.sops.secrets."fastestvpn.auth".path}";
    extraConfig = "/usr/local/etc/openvpn/client/fastestvpn.ovpn";
  };
}
