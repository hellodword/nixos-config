{
  config,
  lib,
  pkgs,
  name,
  inputs,
  vpsSecretsFile,
  ...
}:
let
  ranges = input: lib.filter (line: line != "") (lib.splitString "\n" (builtins.readFile input));
  ipv4 = ranges inputs.cloudflare-ips-v4;
  ipv6 = ranges inputs.cloudflare-ips-v6;
  credentialDirectory = "/var/lib/site-http-origin/credentials/${builtins.hashFile "sha256" vpsSecretsFile}";
  locations = pkgs.writeText "http-origin-locations.conf.in" ''
    location = $ORIGIN_PREFIX {
      proxy_pass http://127.0.0.1:8080/;
    }
    location ^~ $ORIGIN_PREFIX/ {
      proxy_pass http://127.0.0.1:8080/;
    }
    location / {
      return 404;
    }
  '';
in
{
  assertions = [
    {
      assertion = ipv4 != [ ] && ipv6 != [ ];
      message = "The HTTP origin requires both Cloudflare address lists.";
    }
  ];

  deployment.keys.http-origin-prefix = {
    keyCommand = [
      "sops"
      "decrypt"
      "--extract"
      ''["secrets"]["${name}-http-origin-prefix"]''
      (toString vpsSecretsFile)
    ];
    destDir = credentialDirectory;
    user = "root";
    group = "root";
    permissions = "0600";
    uploadAt = "pre-activation";
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
  networking.nftables.tables.site_http_origin = {
    family = "inet";
    content = ''
      set cloudflare4 {
        type ipv4_addr; flags interval;
        elements = { ${lib.concatStringsSep ", " ipv4} }
      }
      set cloudflare6 {
        type ipv6_addr; flags interval;
        elements = { ${lib.concatStringsSep ", " ipv6} }
      }
      chain input {
        # Apply source restrictions before the system firewall accepts established traffic.
        type filter hook input priority -10; policy accept;
        iifname "lo" return
        ip saddr @cloudflare4 tcp dport 443 counter drop
        ip6 saddr @cloudflare6 tcp dport 443 counter drop
        ip saddr @cloudflare4 udp dport 443 counter drop
        ip6 saddr @cloudflare6 udp dport 443 counter drop
        tcp dport 80 ip saddr != @cloudflare4 counter drop
        tcp dport 80 ip6 saddr != @cloudflare6 counter drop
      }
    '';
  };

  services.nginx = {
    enable = true;
    # The location prefix is supplied through a runtime credential; preStart runs nginx -t.
    validateConfigFile = false;
    preStart = ''
      umask 077
      export ORIGIN_PREFIX="$(cat "$CREDENTIALS_DIRECTORY/http-origin-prefix")"
      if [[ ! "$ORIGIN_PREFIX" =~ ^/[A-Za-z0-9_-]+$ ]]; then
        echo 'HTTP origin prefix must be / followed by one URL-safe path segment.' >&2
        exit 1
      fi
      ${pkgs.gettext}/bin/envsubst '$ORIGIN_PREFIX' < ${locations} > /run/nginx/http-origin-locations.conf
    '';
    appendHttpConfig = ''
      map $http_x_forwarded_proto $site_http_origin_scheme {
        default $scheme;
        http http;
        https https;
      }
    '';
    virtualHosts.http-origin = {
      default = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ]
      ++ lib.optional config.networking.enableIPv6 {
        addr = "[::]";
        port = 80;
      };
      extraConfig = ''
        ${lib.concatMapStringsSep "\n" (range: "set_real_ip_from ${range};") (ipv4 ++ ipv6)}
        real_ip_header CF-Connecting-IP;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Proto $site_http_origin_scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_redirect off;
        include /run/nginx/http-origin-locations.conf;
      '';
    };
  };
  systemd.services.nginx.serviceConfig.LoadCredential = [
    "http-origin-prefix:${credentialDirectory}/http-origin-prefix"
  ];
}
