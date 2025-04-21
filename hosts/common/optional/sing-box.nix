{
  pkgs,
  lib,
  persistPath,
  inputs,
  config,
  ...
}:

let
  sbBase = "/var/lib/sing-box";
  logPath = "/var/log/sing-box/log";
  logPathReal = "/var/log/private/sing-box/log";
  sbBaseReal = "/var/lib/private/sing-box";
  sbTemplateFile = "/etc/sing-box/template.json";
  sbOutboundsFile = "/usr/local/etc/sing-box/outbounds.json";
  # sbRulesFile = "/usr/local/etc/sing-box/rules.json";
  sbConfigFile = "${sbBase}/sing-box.json";

  sbGenerate = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [ jq ];
    excludeShellChecks = [
      "SC2086"
      "SC2027"
    ];
    text = ''
      set -x
      cd ${sbBase}
      rm -rf ${sbConfigFile}
      rm -rf config.json.tmp.*

      uids=()

      ${lib.strings.concatStringsSep "\n" (
        map (x: ''
          tmp_val="$(id -u ${x.user} || true)"
          if [ -n "$tmp_val" ]; then
            uids+=("$tmp_val")
          fi
        '') config.me.sing-box-bypass-services
      )}

      IFS=','
      _uids="''${uids[*]}"

      jq "(.inbounds[] | select(.type == \"tun\")).exclude_uid = [$_uids]" ${sbTemplateFile} > config.json.tmp.0

      wgcf_priv="$(cat "${config.sops.secrets."wgcf.priv".path}")"
      jq "(.endpoints[] | select(.name == \"wgcf\")).private_key = \"$wgcf_priv\"" config.json.tmp.0 > config.json.tmp.1

      tags="$(jq '.outbounds[] | .tag' ${sbOutboundsFile} | sed ':a;N;$!ba;s/\n/, /g')"

      jq --argjson tags "[$tags]" '
        .outbounds |= map(
          if .type == "selector" or .type == "urltest" then
            .outbounds += $tags
          else
            .
          end
      )' config.json.tmp.1 > config.json.tmp.2

      jq -s '[.[] | to_entries] | flatten | reduce .[] as $dot ({}; .[$dot.key] += $dot.value)' "config.json.tmp.2" ${sbOutboundsFile} > ${sbConfigFile}

      rm -rf config.json.tmp.*
    '';
  };

  sbBypassUserDelUnresolved = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [
      iproute2
      findutils
      gnugrep
      bash
    ];
    excludeShellChecks = [ "SC2086" ];
    text = ''
      set -x

      ip -4 rule list | grep -oP "(?<=\d:\t)from all uidrange \d+-\d+ goto \d+(?= \[unresolved\])" | xargs -I {} bash -xc 'ip -4 rule del {}' || true
      ip -6 rule list | grep -oP "(?<=\d:\t)from all uidrange \d+-\d+ goto \d+(?= \[unresolved\])" | xargs -I {} bash -xc 'ip -6 rule del {}' || true
    '';
  };

  sbBypassUserDel = pkgs.writeShellApplication {
    name = "exe";
    runtimeInputs = with pkgs; [
      iproute2
      findutils
      gnugrep
      bash
    ];
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
    runtimeInputs = with pkgs; [
      iproute2
      gnugrep
    ];
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

  patched = true;
in
{
  # sing-tun may not working after networking state changes
  # https://github.com/SagerNet/sing-box/issues/1415
  services.networkd-dispatcher =
    let
      ignore_iface = ''
        if [[ "$IFACE" == "lo" ||
          "$IFACE" == "sb-tun" || "$IFACE" == "wgcf" ||
          "$IFACE" =~ ^wg.* ||
          "$IFACE" =~ ^docker.* || "$IFACE" =~ ^br-.* || "$IFACE" =~ ^veth.* ||
          "$IFACE" =~ ^vbox.* ||
          "$IFACE" =~ ^tailscale.*
        ]]; then
          echo "ignored iface $IFACE"
          exit 0
        fi
      '';
    in
    {
      enable = true;
      rules = {
        "restart-sing-box-on-no-carrier" = {
          onState = [ "no-carrier" ];
          script = ''
            #!${pkgs.runtimeShell}
            set -x

            ${ignore_iface}

            echo "Restarting sing-box ..."
            systemctl restart sing-box

            exit 0
          '';
        };
        "restart-sing-box-on-configured" = {
          onState = [ "configured" ];
          script = ''
            #!${pkgs.runtimeShell}
            set -x

            ${ignore_iface}

            ipv4="$(echo "$ADDR" | ${pkgs.gawk}/bin/awk '{print $1}')"
            if [[ "$ipv4" =~ [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} ]]; then
              echo "Restarting sing-box ..."
              systemctl restart sing-box
            fi

            exit 0
          '';
        };
      };
    };

  # "${config.sops.secrets."wgcf.priv".path}";
  sops.secrets."wgcf.priv" = {
    sopsFile = ../../${config.networking.hostName}/secrets/wgcf.priv;
    format = "binary";
  };

  networking.firewall.enable = lib.mkForce false;

  # https://github.com/A1ca7raz/flamework/blob/main/modules/services/client/sing-box/default.nix#L78-L105
  systemd.services =
    lib.mergeAttrs
      (builtins.listToAttrs (
        builtins.map (x: {
          name = x.service;
          value = {
            serviceConfig = {
              ExecStartPre = lib.mkAfter [
                "+${sbBypassUserDel}/bin/exe ${x.user}"
                "+${sbBypassUserAdd}/bin/exe ${x.user}"
              ];
              ExecStop = lib.mkAfter [ "+${sbBypassUserDel}/bin/exe ${x.user}" ];
            };
          };
        }) config.me.sing-box-bypass-services
      ))
      {
        networkd-dispatcher = {
          after = [ "sing-box.service" ];
        };

        sing-box = {
          enable = true;
          description = "Sing-box networking service";
          wantedBy = [ "multi-user.target" ];
          requires = [ "network-online.target" ];
          after = [
            "network-online.target"
            # "nss-lookup.target"
            "systemd-resolved.service"
            "dnsmasq.service"
          ];
          path = with pkgs; [
            curl
            sing-box
          ];

          unitConfig = {
            StartLimitInterval = 5;
            StartLimitBurst = 10;
          };

          serviceConfig = {
            Type = "simple";

            Environment = "USE_HTTP2PING=true";
            ExecStartPre = [
              # Fix perm after debugging sing-box with sudo
              "+${lib.getExe' pkgs.coreutils "coreutils"} --coreutils-prog=chown -R sing-box:sing-box ${sbBaseReal}"
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
            # Proc filesystem
            ProcSubset = "pid";
            ProtectProc = "invisible";
            # Security
            NoNewPrivileges = true;
            # Sandboxing
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            # PrivateDevices = true; # NOT WORK on Tun Mode
            # DeviceAllow = "/dev/net/tun rw";
            DeviceAllow = "/dev/net/tun";
            DevicePolicy = "closed";
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
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            # System Call Filtering
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid"
              "setrlimit"
            ];
          };
        };
      };

  environment.etc."sing-box/template.json".text = builtins.toJSON {
    "$schema" =
      "https://gist.githubusercontent.com/artiga033/fea992d95ad44dc8d024b229223b1002/raw/83c676c1ec9f37af2bce0505da396b5444b30032/sing-box.schema.json";

    dns = {
      fakeip = {
        enabled = true;
        inet4_range = "198.18.0.0/15";
        inet6_range = "fc00::/18";
      };
      final = "dns:proxy";
      independent_cache = true;
      rules = [
        {
          rule_set = [ "lyc8503:geosite:private" ];
          server = "dns:local";
        }
        {
          clash_mode = "direct";
          server = "dns:direct";
        }
        {
          clash_mode = "global";
          server = "dns:proxy";
        }
        {
          query_type = [
            "A"
            "AAAA"
          ];
          rewrite_ttl = 1;
          rule_set = [
            "lyc8503:geosite:geolocation@!cn"
            "lyc8503:geosite:alibaba@!cn"
            "lyc8503:geosite:alibabacloud@!cn"
            "lyc8503:geosite:aliyun@!cn"
            "lyc8503:geosite:bilibili@!cn"
            "lyc8503:geosite:bytedance@!cn"
            "lyc8503:geosite:huawei@!cn"
            "lyc8503:geosite:huaweicloud@!cn"
            "lyc8503:geosite:jd@!cn"
            "lyc8503:geosite:qcloud@!cn"
            "lyc8503:geosite:tencent-games@!cn"
            "lyc8503:geosite:tencent@!cn"
            "lyc8503:geosite:tiktok@!cn"
            "lyc8503:geosite:xiaomi@!cn"
          ];
          server = "dns:fakeip";
        }
        {
          rule_set = [
            "lyc8503:geosite:cn"
            "lyc8503:geosite:geolocation@cn"
            "lyc8503:geosite:google-trust-services@cn"
          ];
          server = "dns:direct";
        }
        {
          query_type = [
            "A"
            "AAAA"
          ];
          rewrite_ttl = 1;
          server = "dns:fakeip";
        }
      ];
      servers = [
        {
          address = "127.0.0.1:55554";
          client_subnet = "140.82.112.3";
          detour = "节点选择";
          strategy = "prefer_ipv4";
          tag = "dns:proxy";
        }
        {
          address = "127.0.0.1:55553";
          detour = "out:DIRECT";
          strategy = "prefer_ipv4";
          tag = "dns:direct";
        }
        {
          address = "local";
          tag = "dns:local";
        }
        {
          address = "rcode://refused";
          tag = "dns:refused";
        }
        {
          address = "fakeip";
          tag = "dns:fakeip";
        }
      ];
      strategy = "prefer_ipv4";
    };

    endpoints = [
      {
        address = inputs.nixos-privates.wgcf."${config.networking.hostName}".address;
        detour = "跳板";
        mtu = 1280;
        name = "wgcf";
        peers = [
          {
            address = "162.159.192.1"; # "engage.cloudflareclient.com";
            allowed_ips = [
              "0.0.0.0/0"
              "::/0"
            ];
            persistent_keepalive_interval = 30;
            port = 2408;
            public_key = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=";
            reserved = [
              0
              0
              0
            ];
          }
        ];
        private_key = "";
        system = true;
        tag = "out:WARP";
        type = "wireguard";
      }
    ];

    experimental = {
      cache_file = {
        enabled = true;
        store_fakeip = true;
      };
    };

    inbounds = [
      {
        address = [
          "172.19.0.1/30"
          "fdfe:dcba:9876::1/126"
        ];
        auto_route = true;
        exclude_uid = [ ];
        interface_name = "sb-tun";
        route_exclude_address = [

          # https://en.wikipedia.org/wiki/Reserved_IP_addresses
          "10.0.0.0/8"
          "127.0.0.0/8"
          "192.0.0.0/24"
          "192.168.0.0/16"
          "198.18.0.0/15"
          "::1/128"

          # bypass tailscale
          # https://tailscale.com/kb/1015/100.x-addresses/
          # https://quanquan.space/viewtopic.php?t=1350
          "100.64.0.0/10"

          "fd7a:115c:a1e0::/48"

          # # for docker bridge network
          # # 172.16.0.0/12 exclude 172.19.0.1/30 because it's the sing-tun inet4_address
          "172.16.0.0/15"
          "172.18.0.0/16"
          "172.19.0.4/30"
          "172.19.0.8/29"
          "172.19.0.16/28"
          "172.19.0.32/27"
          "172.19.0.64/26"
          "172.19.0.128/25"
          "172.19.1.0/24"
          "172.19.2.0/23"
          "172.19.4.0/22"
          "172.19.8.0/21"
          "172.19.16.0/20"
          "172.19.32.0/19"
          "172.19.64.0/18"
          "172.19.128.0/17"
          "172.20.0.0/14"
          "172.24.0.0/13"
        ];
        route_exclude_address_set = [ "lyc8503:geoip:private" ];
        stack = "mixed";
        strict_route = true;
        tag = "in:tun";
        type = "tun";
      }
      {
        listen = "::0";
        listen_port = 10800;
        tag = "in:mixed";
        type = "mixed";
      }
      {
        listen = "127.0.0.1";
        listen_port = 2081;
        tag = "in:REJECT";
        type = "socks";
      }
    ];

    log = {
      disabled = false;
      level = "trace";
      output = logPath;
      timestamp = true;
    };

    ntp = {
      detour = "out:DIRECT";
      enabled = true;
      interval = "30m";
      server = "time.apple.com";
      server_port = 123;
    };

    outbounds = [
      {
        server = "127.0.0.1";
        server_port = 2081;
        tag = "out:REJECT";
        type = "socks";
      }
      {
        domain_strategy = "prefer_ipv4";
        tag = "out:DIRECT";
        type = "direct";
      }
      {
        outbounds = [
          "自动选择"
          "out:REJECT"
          "out:DIRECT"
          "out:WARP"
        ];
        tag = "节点选择";
        type = "selector";
      }
      (
        {
          outbounds = [ ];
          tag = "自动选择";
          type = "urltest";
        }
        // (lib.optionalAttrs patched {
          idle_timeout = "30m";
          interrupt_exist_connections = false;
          interval = "1s";
          tolerance = 300;
          url = "https://1.1.1.1";
        })
      )
      {
        outbounds = [
          "节点选择"
          "out:DIRECT"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "GLOBAL";
        type = "selector";
      }
      {
        outbounds = [
          "out:DIRECT"
          "out:REJECT"
          "节点选择"
          "自动选择"
        ];
        tag = "私有网络";
        type = "selector";
      }
      {
        outbounds = [
          "out:DIRECT"
          "节点选择"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "国内服务";
        type = "selector";
      }
      {
        outbounds = [
          "节点选择"
          "out:REJECT"
          "out:DIRECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "加密货币";
        type = "selector";
      }
      {
        outbounds = [
          "节点选择"
          "out:DIRECT"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "隐私相关";
        type = "selector";
      }
      {
        outbounds = [
          "节点选择"
          "out:DIRECT"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "流媒体";
        type = "selector";
      }
      {
        outbounds = [
          "节点选择"
          "out:DIRECT"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "非中国";
        type = "selector";
      }
      {
        outbounds = [
          "节点选择"
          "out:DIRECT"
          "out:REJECT"
          "out:WARP"
          "自动选择"
        ];
        tag = "漏网之鱼";
        type = "selector";
      }
      {
        outbounds = [
          "自动选择"
          "out:DIRECT"
        ];
        tag = "跳板";
        type = "selector";
      }
    ];
    route = {
      auto_detect_interface = true;
      final = "漏网之鱼";
      rule_set = [
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:geolocation@cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-geolocation-cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:private";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-private.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:private";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-private.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:geolocation@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-geolocation-!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:alibaba@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-alibaba@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:alibabacloud@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-alibabacloud@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:aliyun@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-aliyun@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:bilibili@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-bilibili@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:bytedance@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-bytedance@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:huawei@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-huawei@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:huaweicloud@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-huaweicloud@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:jd@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-jd@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:qcloud@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-qcloud@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:tencent-games@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tencent-games@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:tencent@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tencent@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:tiktok@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tiktok@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:xiaomi@!cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-xiaomi@!cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:category:cryptocurrency";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-category-cryptocurrency.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:category:cryptocurrency@cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-category-cryptocurrency@cn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:protonmail";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-protonmail.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:telegram";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-telegram.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:telegram";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-telegram.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:tor";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-tor.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:tor";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-tor.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:torproject";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-torproject.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:category:porn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-category-porn.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:netflix";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-netflix.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:netflix";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-netflix.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:hulu";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-hulu.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:hbo";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-hbo.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:disney";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-disney.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:spotify";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-spotify.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:primevideo";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-primevideo.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:youtube";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-youtube.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "DustinWin:geosite:appletv";
          type = "remote";
          url = "https://raw.githubusercontent.com/DustinWin/ruleset_geodata/refs/heads/sing-box-ruleset/appletv.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:imgur";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-imgur.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:paypal";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-paypal.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:pixiv";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-pixiv.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:cloudflare";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-cloudflare.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:cloudflare";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-cloudflare.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:openai";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-openai.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:reddit";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-reddit.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:fastly";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-fastly.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:fastly";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-fastly.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:cloudfront";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-cloudfront.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:facebook";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-facebook.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:facebook";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-facebook.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geoip:twitter";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geoip/geoip-twitter.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:twitter";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-twitter.srs";
        }
        {
          download_detour = "自动选择";
          format = "binary";
          tag = "lyc8503:geosite:google-trust-services@cn";
          type = "remote";
          url = "https://raw.githubusercontent.com/lyc8503/sing-box-rules/refs/heads/rule-set-geosite/geosite-google-trust-services%40cn.srs";
        }
      ];
      rules = [
        {
          action = "reject";
          inbound = [ "in:REJECT" ];
        }
        { action = "sniff"; }
        # {
        #   action = "hijack-dns";
        #   protocol = "dns";
        # }
        {
          clash_mode = "direct";
          outbound = "out:DIRECT";
        }
        {
          clash_mode = "global";
          outbound = "GLOBAL";
        }
        {
          outbound = "私有网络";
          rule_set = [
            "lyc8503:geosite:private"
            "lyc8503:geoip:private"
          ];
        }
        {
          ip_is_private = true;
          outbound = "私有网络";
        }
        {
          outbound = "加密货币";
          rule_set = [
            "lyc8503:geosite:category:cryptocurrency"
            "lyc8503:geosite:category:cryptocurrency@cn"
          ];
        }
        {
          outbound = "隐私相关";
          rule_set = [
            "lyc8503:geosite:protonmail"
            "lyc8503:geoip:telegram"
            "lyc8503:geosite:telegram"
            "lyc8503:geoip:tor"
            "lyc8503:geosite:tor"
            "lyc8503:geosite:torproject"
            "lyc8503:geosite:category:porn"
          ];
        }
        {
          outbound = "流媒体";
          rule_set = [
            "lyc8503:geoip:netflix"
            "lyc8503:geosite:netflix"
            "lyc8503:geosite:hulu"
            "lyc8503:geosite:hbo"
            "lyc8503:geosite:disney"
            "lyc8503:geosite:spotify"
            "lyc8503:geosite:primevideo"
            "lyc8503:geosite:youtube"
            "DustinWin:geosite:appletv"
          ];
        }
        {
          outbound = "非中国";
          rule_set = [
            "lyc8503:geosite:geolocation@!cn"
            "lyc8503:geosite:alibaba@!cn"
            "lyc8503:geosite:alibabacloud@!cn"
            "lyc8503:geosite:aliyun@!cn"
            "lyc8503:geosite:bilibili@!cn"
            "lyc8503:geosite:bytedance@!cn"
            "lyc8503:geosite:huawei@!cn"
            "lyc8503:geosite:huaweicloud@!cn"
            "lyc8503:geosite:jd@!cn"
            "lyc8503:geosite:qcloud@!cn"
            "lyc8503:geosite:tencent-games@!cn"
            "lyc8503:geosite:tencent@!cn"
            "lyc8503:geosite:tiktok@!cn"
            "lyc8503:geosite:xiaomi@!cn"
          ];
        }
        {
          outbound = "国内服务";
          rule_set = [
            "lyc8503:geoip:cn"
            "lyc8503:geosite:cn"
            "lyc8503:geosite:geolocation@cn"
            "lyc8503:geosite:google-trust-services@cn"
          ];
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

  services.logrotate.settings.sing-box = {
    files = [ logPathReal ];
    frequency = "daily";
    rotate = 7;
    size = "128M";
    # compress = true;
    # delaycompress = true;
    # missingok = true;
    # notifempty = true;
    postrotate = "systemctl restart sing-box";
  };
}
