{
  config,
  lib,
  pkgs,
  node,
  vps,
  ...
}:
let
  name = config.networking.hostName;
  peers = lib.filterAttrs (peer: _: peer != name) vps.nodes;
  release = "/var/lib/site-vps/releases/${node.release}";
  certDirectory = "site-vps-certificate/${node.certificateId}";
  certState = "/var/lib/${certDirectory}";
  certificate = "${certState}/current";
  interface = node.interface or "eth0";
  web = node.web or { };
  hardened = import ../../lib/service-hardening.nix;
  reload = pkgs.writeShellScript "reload-vps-certificate" ''
    set -eu
    if [ -f ${certState}/changed ]; then
      rm ${certState}/changed
      ${pkgs.systemd}/bin/systemctl --no-block try-restart site-vps-proxy.service ${
        lib.optionalString (web != { }) "nginx.service"
      }
    fi
  '';
in
{
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.firewall = {
    allowedTCPPorts = [ 443 ];
    allowedUDPPorts = [ node.udpPort ];
    filterForward = true;
    extraForwardRules = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: peer: ''
        iifname "${interface}" ip daddr ${peer.address} udp dport ${toString peer.udpPort} ct status dnat accept
      '') peers
    );
  };
  networking.nftables.tables.site_vps = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (_: peer: ''
            iifname "${interface}" fib daddr type local udp dport ${toString peer.udpPort} dnat to ${peer.address}:${toString peer.udpPort}
          '') peers
        )}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (_: peer: ''
            oifname "${interface}" ip daddr ${peer.address} udp dport ${toString peer.udpPort} ct status dnat masquerade
          '') peers
        )}
      }
    '';
  };
  services.haproxy = {
    enable = true;
    config = ''
      global
        maxconn 2048
      defaults
        mode tcp
        timeout connect 5s
        timeout client 5m
        timeout server 5m
      frontend tls
        bind 0.0.0.0:443
        tcp-request inspect-delay 5s
        tcp-request content accept if { req.ssl_hello_type 1 }
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (peerName: peer: ''
            use_backend proxy-${peerName} if { req.ssl_sni -i ${peer.serverName} }
          '') vps.nodes
        )}
        ${lib.optionalString (
          web != { }
        ) "use_backend web if { req.ssl_sni -i ${lib.concatStringsSep " " (builtins.attrNames web)} }"}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (peerName: peer: ''
          backend proxy-${peerName}
            server owner ${if peerName == name then "127.0.0.1:14443" else "${peer.address}:443"}
        '') vps.nodes
      )}
      ${lib.optionalString (web != { }) ''
        backend web
          server nginx 127.0.0.1:18443 send-proxy-v2
      ''}
    '';
  };
  users.groups.site-vps-certificate = { };
  users.users.site-vps-certificate = {
    isSystemUser = true;
    group = "site-vps-certificate";
  };
  systemd.services.site-vps-certificate = {
    description = "Fetch the VPS TLS certificate";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.openssl ];
    environment.SSL_CERT_FILE = config.security.pki.caBundle;
    serviceConfig = hardened // {
      Type = "oneshot";
      DynamicUser = false;
      User = "site-vps-certificate";
      Group = "site-vps-certificate";
      StateDirectory = certDirectory;
      StateDirectoryMode = "0700";
      LoadCredential = [ "request:${release}/certificate.json" ];
      ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/vps/certificate.py} --request %d/request --state ${certState} --ca-file ${config.security.pki.caBundle}";
      ExecStartPost = "+${reload}";
      TimeoutStartSec = "2min";
    };
  };
  systemd.timers.site-vps-certificate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
      OnBootSec = "2min";
    };
  };
  systemd.services.site-vps-proxy = {
    description = "Authenticated VPS proxy exits";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "site-vps-certificate.service"
      "network-online.target"
    ];
    after = [
      "site-vps-certificate.service"
      "network-online.target"
    ];
    restartTriggers = [ release ];
    serviceConfig = hardened // {
      LoadCredential = [
        "proxy.json:${release}/proxy.json"
        "tls.crt:${certificate}/tls.crt"
        "tls.key:${certificate}/tls.key"
      ];
      ExecStartPre = "${pkgs.sing-box}/bin/sing-box check -c %d/proxy.json";
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c %d/proxy.json";
      Restart = "on-failure";
      RestartSec = "30s";
      LimitNOFILE = 65536;
      RestrictAddressFamilies = hardened.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    };
  };
  services.nginx = lib.mkIf (web != { }) {
    enable = true;
    virtualHosts = lib.mapAttrs (_: upstream: {
      onlySSL = true;
      listen = [
        {
          addr = "127.0.0.1";
          port = 18443;
          ssl = true;
          proxyProtocol = true;
        }
      ];
      sslCertificate = "/run/credentials/nginx.service/tls.crt";
      sslCertificateKey = "/run/credentials/nginx.service/tls.key";
      locations."/".proxyPass = upstream;
      extraConfig = "set_real_ip_from 127.0.0.1; real_ip_header proxy_protocol;";
    }) web;
  };
  systemd.services.nginx = lib.mkIf (web != { }) {
    after = [ "site-vps-certificate.service" ];
    wants = [ "site-vps-certificate.service" ];
    serviceConfig.LoadCredential = [
      "tls.crt:${certificate}/tls.crt"
      "tls.key:${certificate}/tls.key"
    ];
  };
}
