{ config, lib, ... }:

let
  caBundle = toString config.security.pki.caBundle;
in
{
  systemd.services = lib.genAttrs [ "sing-box" "mosdns" "mosdns-cn" "tailscaled" ] (_: {
    environment = {
      SSL_CERT_FILE = caBundle;
      SSL_CERT_DIR = builtins.dirOf caBundle;
    };
    restartTriggers = [ config.security.pki.caBundle ];
  });
}
