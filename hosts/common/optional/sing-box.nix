{ pkgs, lib, persistPath, inputs, config, ... }:

let
  sbBase = "/var/lib/sing-box";
  sbBaseReal = "/var/lib/private/sing-box";
  sbTemplateFile = "/etc/sing-box/template.json";
  sbOutboundsFile = "/usr/local/etc/sing-box/outbounds.json";
  sbConfigFile = "${sbBase}/sing-box.json";
  sbGenerate = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ jq ];
    excludeShellChecks = [ "SC2086" "SC2027" ];
    text = ''
      set -x
      cd ${sbBase}
      rm -rf ${sbConfigFile}
      rm -rf config.json.tmp.*

      uids=()

      ${lib.strings.concatStringsSep "\n" (map (x: ''
      ${x.user}="$(id -u ${x.user} || true)"
      if [ -n "''$${x.user}" ]; then
        uids+=("''$${x.user}")
      fi
      '') config.me.sing-box-bypass-services)}

      IFS=','
      _uids="''${uids[*]}"

      jq "(.inbounds[] | select(.type == \"tun\")).exclude_uid = [$_uids]" ${sbTemplateFile} > config.json.tmp.0

      wgcf_priv="$(cat "${config.sops.secrets."wgcf.priv".path}")"
      jq "(.outbounds[] | select(.tag == \"wgcf\")).private_key = \"$wgcf_priv\"" config.json.tmp.0 > config.json.tmp.1

      proxy_tags="$(jq '.outbounds[] | select(.tag | startswith("proxy:")).tag' ${sbOutboundsFile} | sed ':a;N;$!ba;s/\n/, /g')"
      hideme_tags="$(jq '.outbounds[] | select(.tag | startswith("hideme:")).tag' ${sbOutboundsFile} | sed ':a;N;$!ba;s/\n/, /g')"

      jq "(.outbounds[] | select(.tag == \"auto:proxy\")).outbounds = [$proxy_tags]" config.json.tmp.1 > config.json.tmp.2
      jq "(.outbounds[] | select(.tag == \"auto:hideme\")).outbounds = [$hideme_tags]" config.json.tmp.2 > config.json.tmp.3

      jq -s '[.[] | to_entries] | flatten | reduce .[] as $dot ({}; .[$dot.key] += $dot.value)' "config.json.tmp.3" ${sbOutboundsFile} > ${sbConfigFile}
      rm -rf config.json.tmp.*
    '';
  };
  sbBypassUserDelUnresolved = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ iproute2 findutils gnugrep bash ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      ip -4 rule list | grep -oP "(?<=\d:\t)from all uidrange \d+-\d+ goto \d+(?= \[unresolved\])" | xargs -I {} bash -xc 'ip -4 rule del {}' || true
      ip -6 rule list | grep -oP "(?<=\d:\t)from all uidrange \d+-\d+ goto \d+(?= \[unresolved\])" | xargs -I {} bash -xc 'ip -6 rule del {}' || true
    '';
  };
  sbBypassUserDel = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ iproute2 findutils gnugrep bash ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      ${sbBypassUserDelUnresolved}/bin/exe

      _USER_NAME="$1"
      [ -n "$_USER_NAME" ]

      _USER_ID="$(id -u "$_USER_NAME" || true)"
      if [ -n "$_USER_ID" ]; then
          ip -4 rule list | grep -oP "(?<=\d:\t)from all uidrange $_USER_ID-$_USER_ID goto \d+" | xargs -I {} bash -xc 'ip -4 rule del {}' || true
          ip -6 rule list | grep -oP "(?<=\d:\t)from all uidrange $_USER_ID-$_USER_ID goto \d+" | xargs -I {} bash -xc 'ip -6 rule del {}' || true
      fi
    '';
  };
  sbBypassUserAdd = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ iproute2 gnugrep ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      _USER_NAME="$1"
      [ -n "$_USER_NAME" ]

      _IPV4_ID="$(ip -4 rule list | grep -oP '^\d+(?=:\tfrom all nop$)' || true)"
      _IPV6_ID="$(ip -6 rule list | grep -oP '^\d+(?=:\tfrom all nop$)' || true)"
      _USER_ID="$(id -u "$_USER_NAME" || true)"
      if [ -n "$_USER_ID" ]; then
          if [ -n "$_IPV4_ID" ]; then
              ip -4 rule add from all uidrange $_USER_ID-$_USER_ID goto "$_IPV4_ID"
          fi
          if [ -n "$_IPV6_ID" ]; then
              ip -6 rule add from all uidrange $_USER_ID-$_USER_ID goto "$_IPV6_ID"
          fi
      fi
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    sing-box
  ];

  # "${config.sops.secrets."wgcf.priv".path}";
  sops.secrets."wgcf.priv" = {
    sopsFile = ../../${config.networking.hostName}/secrets/wgcf.priv;
    format = "binary";
  };

  networking.firewall.enable = lib.mkForce false;

  # https://github.com/A1ca7raz/flamework/blob/main/modules/services/client/sing-box/default.nix#L78-L105
  systemd.services = lib.mergeAttrs
    (
      builtins.listToAttrs (builtins.map
        (x: {
          name = x.service;
          value = {
            serviceConfig = {
              ExecStartPre = lib.mkAfter [
                "+${sbBypassUserDel}/bin/exe ${x.user}"
                "+${sbBypassUserAdd}/bin/exe ${x.user}"
              ];
              ExecStop = lib.mkAfter [
                "+${sbBypassUserDel}/bin/exe ${x.user}"
              ];
            };
          };
        })
        config.me.sing-box-bypass-services)
    )
    {
      sing-box = {
        enable = true;
        description = "Sing-box networking service";
        wantedBy = [ "multi-user.target" ];
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = with pkgs; [ curl sing-box ];

        serviceConfig = {
          Type = "simple";

          Environment = "USE_HTTP2PING=true";
          ExecStartPre = [
            "+${sbGenerate}/bin/exe"
          ];
          ExecStop = (map (x: "+${sbBypassUserDel}/bin/exe ${x.user}") config.me.sing-box-bypass-services);
          ExecStart = "${pkgs.sing-box}/bin/sing-box run --disable-color -D ${sbBase} -c ${sbConfigFile}";

          # Sing-box Auto Update
          Restart = "on-failure";
          RestartPreventExitStatus = 23;

          # # OOM Killer
          # OOMPolicy = "kill";
          # MemoryMax = "200M";

          DynamicUser = "yes";
          LogsDirectory = "sing-box";
          RuntimeDirectory = "sing-box";
          StateDirectory = "sing-box";
          # Capabilities
          CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW";
          AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW";
          # # Proc filesystem
          # ProcSubset = "pid";
          # ProtectProc = "invisible";
          # Security
          NoNewPrivileges = true;
          # Sandboxing
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          # PrivateDevices = true; # NOT WORK on Tun Mode
          # DeviceAllow = "/dev/net/tun rw";
          PrivateMounts = true;
          PrivateTmp = true;
          # PrivateUsers = true;          # NOT WORK on Tun Mode
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RemoveIPC = true;
          RestrictAddressFamilies = "AF_INET AF_INET6 AF_NETLINK";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          # System Call Filtering
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid" "setrlimit" ];
        };
      };
    };

  environment.etc."sing-box/template.json".text = builtins.toJSON {
    "$schema" =
      "https://gist.githubusercontent.com/artiga033/fea992d95ad44dc8d024b229223b1002/raw/83c676c1ec9f37af2bce0505da396b5444b30032/sing-box.schema.json";
    dns = {
      disable_cache = true;
      fakeip = {
        enabled = true;
        inet4_range = "198.18.0.0/15";
        inet6_range = "fc00::/18";
      };
      final = "dns:global";
      rules = [ ];
      servers = [
        {
          address = "local";
          address_strategy = "prefer_ipv4";
          detour = "direct";
          strategy = "prefer_ipv4";
          tag = "dns:global";
        }
        {
          address = "fakeip";
          address_strategy = "prefer_ipv4";
          strategy = "prefer_ipv4";
          tag = "dns:fakeip";
        }
      ];
    };
    experimental = {
      cache_file = {
        enabled = true;
        store_fakeip = true;
      };
    };
    inbounds = [
      {
        auto_route = true;
        inet4_address = "172.19.0.1/30";
        inet6_address = "fdfe:dcba:9876::1/126";
        interface_name = "sb-tun";
        sniff = true;
        strict_route = false;
        tag = "in:tun";
        type = "tun";
      }
      # listen on ipv4 all and ipv6 local
      # curl ip.sb --proxy socks5h://localhost:10800 -4
      # curl ip.sb --proxy socks5h://localhost:10800 -6
      {
        listen = "0.0.0.0";
        listen_port = 10800;
        sniff = true;
        tag = "in:mixed";
        type = "mixed";
      }
      {
        listen = "::1";
        listen_port = 10800;
        sniff = true;
        tag = "in:mixed";
        type = "mixed";
      }
    ];
    log = {
      disabled = false;
      level = "trace";
      output = "/var/log/sing-box/log";
      timestamp = true;
    };
    outbounds = [
      {
        tag = "out:block";
        type = "block";
      }
      {
        tag = "out:direct:default";
        type = "direct";
      }
      {
        tag = "out:dns";
        type = "dns";
      }
      {
        detour = "auto:proxy";
        interface_name = "wgcf";
        local_address = inputs.nixos-privates.wgcf."${config.networking.hostName}".address;
        mtu = 1280;
        private_key = "";
        peer_public_key = inputs.nixos-privates.wgcf."${config.networking.hostName}".publicKey;
        server = "162.159.192.1";
        server_port = 2408;
        system_interface = true;
        tag = "wgcf";
        type = "wireguard";
      }
      {
        idle_timeout = "30m";
        interrupt_exist_connections = false;
        interval = "1s";
        # _outbounds = [
        #   "proxy:"
        # ];
        tag = "auto:proxy";
        tolerance = 25;
        type = "urltest";
        url = "https://1.1.1.1"; # "https://connectivitycheck.gstatic.com/generate_204";
      }
      {
        idle_timeout = "30m";
        interrupt_exist_connections = false;
        interval = "1s";
        # _outbounds = [
        #   "hideme:"
        # ];
        tag = "auto:hideme";
        tolerance = 25;
        type = "urltest";
        url = "https://1.1.1.1"; # "https://connectivitycheck.gstatic.com/generate_204";
      }
    ];
    route = {
      auto_detect_interface = true;
      final = "auto:hideme";
      rule_set = [
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:cn";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:cn";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:protonmail";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-protonmail.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:telegram";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:imgur";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-imgur.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:paypal";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-paypal.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:pixiv";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-pixiv.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:category-cryptocurrency";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-cryptocurrency.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:category-novel";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-novel.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:category-porn";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-porn.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:cloudflare";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cloudflare.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:openai";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geosite:reddit";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-reddit.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:telegram";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-telegram.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:cloudflare";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudflare.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:fastly";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-fastly.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:cloudfront";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cloudfront.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:facebook";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-facebook.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:netflix";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-netflix.srs";
        }
        {
          download_detour = "auto:proxy";
          format = "binary";
          tag = "geoip:twitter";
          type = "remote";
          url =
            "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-twitter.srs";
        }
      ];
      rules = [
        {
          ip_is_private = true;
          outbound = "out:direct:default";
        }
        {
          outbound = "out:dns";
          protocol = "dns";
        }
        {
          outbound = "out:direct:default";
          rule_set = "geoip:cn";
        }
        {
          outbound = "out:direct:default";
          rule_set = "geosite:cn";
        }
        {
          ip_version = 6;
          outbound = "auto:hideme"; # "wgcf";
        }
        {
          outbound = "auto:hideme";
          port = 22;
        }
        {
          outbound = "auto:hideme";
          port = 222;
        }
        {
          outbound = "auto:hideme";
          port = 2222;
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:protonmail";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:telegram";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:imgur";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:paypal";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:pixiv";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:category-cryptocurrency";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:category-novel";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:category-porn";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:cloudflare";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:openai";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geosite:reddit";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:telegram";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:cloudflare";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:fastly";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:cloudfront";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:facebook";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:netflix";
        }
        {
          outbound = "auto:hideme";
          rule_set = "geoip:twitter";
        }
      ];
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      sbBaseReal
      "/var/log/private/sing-box"
      "/usr/local/etc/sing-box"
    ];
  };
}
