{ config, ... }:

{
  sops.secrets."wgcf" = {
    sopsFile = ../../../${config.networking.hostName}/secrets/wgcf.conf;
    format = "binary";
  };

  wg.servers."wgcf" = {
    config = "${config.sops.secrets."wgcf".path}";
  };
}
