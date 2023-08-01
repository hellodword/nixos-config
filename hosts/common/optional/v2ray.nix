# UDP: https://github.com/v2fly/v2ray-core/issues/68

{ lib, config, pkgs, persistPath, inputs, ... }:

let
  tproxyPort = 12345;

  generatedPath = "/usr/local/etc/v2ray/generated.json";
  outboundsPath = "/usr/local/etc/v2ray/outbounds.json";

  # https://github.com/jqlang/jq/issues/502#issuecomment-50063847
  generate = pkgs.writeShellApplication {
    name = "v2ray.generate";
    runtimeInputs = with pkgs; [ jq ];
    text = ''
      jq -s '[.[] | to_entries] | flatten | reduce .[] as $dot ({}; .[$dot.key] += $dot.value)' "${config.sops.templates.v2ray.path}" ${outboundsPath} > ${generatedPath}
    '';
  };

  stop = pkgs.writeShellApplication {
    name = "v2ray.stop";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 ];
    text = ''
      ip rule del fwmark 1 table 100 || true
      ip route del local default dev lo table 100 || true
      iptables -w 3 -t mangle -D PREROUTING -j V2RAY || true
      iptables -w 3 -t mangle -D OUTPUT -j V2RAY_MARK || true
      iptables -w 3 -t mangle -F V2RAY || true
      iptables -w 3 -t mangle -X V2RAY || true
      iptables -w 3 -t mangle -F V2RAY_MARK || true
      iptables -w 3 -t mangle -X V2RAY_MARK || true
      iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT || true
      iptables -w 3 -t mangle -F DIVERT || true
      iptables -w 3 -t mangle -X DIVERT || true
    '';
  };

  startPre = pkgs.writeShellApplication {
    name = "v2ray.startPre";
    runtimeInputs = with pkgs; [ ipset iptables iproute2 procps ];
    text = ''
      ${stop}/bin/v2ray.stop

      ${lib.strings.optionalString config.virtualisation.docker.enable ''
      sysctl net.bridge.bridge-nf-call-ip6tables=0  || true
      sysctl net.bridge.bridge-nf-call-iptables=0   || true
      sysctl net.bridge.bridge-nf-call-arptables=0  || true
      ''}

      ipset create v2ray_bypass hash:ip family inet || true
      ipset list v2ray_bypass > /dev/null

      ip rule add fwmark 1 table 100
      ip route add local default dev lo table 100

      # 新建 DIVERT 规则，避免已有连接的包二次通过 TPROXY，理论上有一定的性能提升
      iptables -t mangle -N DIVERT || true
      iptables -t mangle -A DIVERT -j MARK --set-mark 1
      iptables -t mangle -A DIVERT -j ACCEPT
      iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT

      # ebtables udp
      # https://hackerl.github.io/2020/09/11/%E8%BD%AF%E8%B7%AF%E7%94%B1%E6%8A%98%E8%85%BE%E8%AE%B0%E5%BD%95%E4%BA%8C/
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 127.0.0.0/8 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 10.0.0.0/8 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 169.254.0.0/16 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 192.168.0.0/16 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 224.0.0.0/4 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 240.0.0.0/4 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 172.16.0.0/12 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp --ip-destination 255.255.255.255 -j ACCEPT
      # ebtables-legacy -t broute -A BROUTING -p ipv4 --ip-proto udp -j redirect --redirect-target DROP

      iptables -w 3 -t mangle -N V2RAY
      iptables -w 3 -t mangle -A V2RAY -d 0.0.0.0/8 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 10.0.0.0/8 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 100.64.0.0/10 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 127.0.0.0/8 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 169.254.0.0/16 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 172.16.0.0/12 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 192.0.0.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 192.0.2.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 192.88.99.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 192.168.0.0/16 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 198.18.0.0/15 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 198.51.100.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 203.0.113.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 224.0.0.0/4 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 240.0.0.0/4 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -d 255.255.255.255/32 -j RETURN
      iptables -w 3 -t mangle -A V2RAY -p tcp -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      iptables -w 3 -t mangle -A V2RAY -p udp -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      iptables -w 3 -t mangle -A PREROUTING -j V2RAY

      iptables -w 3 -t mangle -N V2RAY_MARK
      iptables -w 3 -t mangle -A V2RAY_MARK -d 0.0.0.0/8 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 10.0.0.0/8 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 100.64.0.0/10 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 169.254.0.0/16 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 172.16.0.0/12 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 192.0.0.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 192.0.2.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 192.88.99.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 192.168.0.0/16 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 198.18.0.0/15 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 198.51.100.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 203.0.113.0/24 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 224.0.0.0/4 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 240.0.0.0/4 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -d 255.255.255.255/32 -j RETURN
      iptables -w 3 -t mangle -A V2RAY_MARK -j RETURN -m mark --mark 2
      iptables -w 3 -t mangle -A V2RAY_MARK -p tcp -j MARK --set-mark 1
      iptables -w 3 -t mangle -A V2RAY_MARK -p udp -j MARK --set-mark 1
      iptables -w 3 -t mangle -A OUTPUT -j V2RAY_MARK


      # 本意是劫持所有 53 DNS 让 v2ray 处理，但控制好网关就不需要
      # iptables -w 3 -t mangle -I V2RAY -p udp -d 10.0.0.0/8 --dport 53 -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      # iptables -w 3 -t mangle -I V2RAY -p udp -d 100.64.0.0/10 --dport 53 -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      # iptables -w 3 -t mangle -I V2RAY -p udp -d 172.16.0.0/12 --dport 53 -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      # iptables -w 3 -t mangle -I V2RAY -p udp -d 192.168.0.0/16 --dport 53 -j TPROXY --on-port ${toString tproxyPort} --tproxy-mark 1
      # iptables -w 3 -t mangle -I V2RAY_MARK -p udp -d 10.0.0.0/8 --dport 53 -j MARK --set-mark 1
      # iptables -w 3 -t mangle -I V2RAY_MARK -p udp -d 100.64.0.0/10 --dport 53 -j MARK --set-mark 1
      # iptables -w 3 -t mangle -I V2RAY_MARK -p udp -d 172.16.0.0/12 --dport 53 -j MARK --set-mark 1
      # iptables -w 3 -t mangle -I V2RAY_MARK -p udp -d 192.168.0.0/16 --dport 53 -j MARK --set-mark 1

      # iptables -w 3 -t mangle -I V2RAY -p udp -d 114.114.114.114 --dport 53 -j RETURN
      # iptables -w 3 -t mangle -I V2RAY -p tcp -d 114.114.114.114 --dport 53 -j RETURN
      # iptables -w 3 -t mangle -I V2RAY_MARK -p udp -d 114.114.114.114 --dport 53 -j RETURN
      # iptables -w 3 -t mangle -I V2RAY_MARK -p tcp -d 114.114.114.114 --dport 53 -j RETURN

      iptables -w 3 -t mangle -I V2RAY -m set --match-set v2ray_bypass dst -j RETURN
      iptables -w 3 -t mangle -I V2RAY_MARK -m set --match-set v2ray_bypass dst -j RETURN

      # # 自身
      iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner v2ray -j RETURN

      # systemd-resolve
      iptables -w 3 -t mangle -I V2RAY_MARK -m owner --uid-owner systemd-resolve -j RETURN
    '';
  };
in
{
  # !important! or will not work with docker bridge network
  networking.firewall.enable = lib.mkForce false;

  environment.systemPackages = with pkgs; [ iproute2 iptables ];

  services.v2ray = {
    enable = true;
    package = pkgs.v2ray;
    configFile = generatedPath;
  };

  #   https://github.com/linyinfeng/dotfiles/blob/3e040c5ebe560bac7e302031b0c0c211f4739df0/nixos/modules/services/portal.nix#L102
  #   https://github.com/jz8132543/flakes/blob/d538c1ff5ffbec5d89eb08cd839fb55eac4b5da3/nixos/modules/services/tuic.nix#L31
  #   https://github.com/search?q=%2Fsops%5C.templates%2F+language%3Anix&type=code

  sops.templates.v2ray.content = builtins.toJSON {
    "log" = {
      "access" = "/var/log/v2ray/v2ray.log";
      "error" = "/var/log/v2ray/v2ray.log";
      "loglevel" = "debug";
    };

    "inbounds" = [
      {
        "tag" = "in-tproxy";
        "port" = tproxyPort;
        "protocol" = "dokodemo-door";
        "settings" = {
          "address" = "0.0.0.0";
          "network" = "tcp,udp";
          "followRedirect" = true;
        };
        "sniffing" = {
          "enabled" = false;
          "destOverride" = [
            "http"
            "tls"
          ];
        };
        "streamSettings" = {
          "sockopt" = {
            "tproxy" = "tproxy";
          };
        };
      }
      {
        "tag" = "in-socks";
        "port" = inputs.nixos-privates.v2ray.inbounds.socks5Port;
        "listen" = "0.0.0.0";
        "protocol" = "socks";
        "sniffing" = {
          "enabled" = false;
        };
        "settings" = {
          "auth" = "noauth";
          "udp" = true;
          "allowTransparent" = false;
        };
      }
      {
        "tag" = "in-http";
        "port" = inputs.nixos-privates.v2ray.inbounds.httpPort;
        "listen" = "0.0.0.0";
        "protocol" = "http";
        "settings" = {
          "udp" = false;
          "allowTransparent" = false;
        };
      }
    ];

    "routing" = {
      "domainStrategy" = "IPIfNonMatch";
      "domainMatcher" = "mph";
      "balancers" = [
        {
          "tag" = "balancer-default";
          "fallbackTag" = "special:block";
          "selector" = [
            "proxy:us:"
          ];
          "observerTag" = "observe-default";
          "strategy" = {
            "type" = "leastping";
            "settings" = {
              "baselines" = [
                "400ms"
                "600ms"
              ];
              "expected" = 1;
              "maxRTT" = "7000ms";
              "tolerance" = 0.5;
            };
          };
        }
      ];

      "rules" = [
        {
          "type" = "field";
          "inboundTag" = [
            "in-socks"
            "in-http"
            "in-tproxy"
          ];
          "ip" = [
            "geoip:private"
          ];
          "outboundTag" = "special:direct";
        }
        {
          "type" = "field";
          "inboundTag" = [
            "in-socks"
            "in-http"
            "in-tproxy"
          ];
          "ip" = [
            "geoip:cn"
          ];
          "outboundTag" = "special:direct";
        }
        {
          "type" = "field";
          "inboundTag" = [
            "in-tproxy"
          ];
          "domain" = [
            "geosite:private"
            "geosite:cn"
          ];
          "outboundTag" = "special:direct";
        }
        {
          "type" = "field";
          "inboundTag" = [
            "in-socks"
            "in-http"
            "in-tproxy"
          ];
          "balancerTag" = "balancer-default";
        }
      ];
    };


    "burstObservatory" = {
      "tag" = "observe-default";
      "subjectSelector" = [
        "proxy:us:"
      ];
      "pingConfig" = {
        "destination" = "http://www.google.com/gen_204";
        "connectivity" = "http://www.msftncsi.com/ncsi.txt";
        "interval" = "60s";
        "samplingCount" = 10;
        "timeout" = "7000ms";
      };
    };


    /*
        命名规范
        <用途>:<落地>:<协议>:<中转-中转-中转>
        用途: special 或者 proxy
        落地: block 或者 direct 或者落地服务器代号
        协议: cf / hy / tuic
        中转: 代号或者 IP
    */
    "outbounds" = [

      {
        "tag" = "special:block";
        "protocol" = "blackhole";
      }
      {
        "tag" = "special:direct";
        "protocol" = "freedom";
        "settings" = {
          "domainStrategy" = "UseIPv4";
        };
        "streamSettings" = {
          # "sockopt" = {
          #   "mark" = 2;
          # };
        };
      }
    ];

  };

  systemd.services."v2ray" = {
    path = with pkgs; [ iproute2 iptables ipset ];
    environment =
      let
        assets = pkgs.symlinkJoin {
          name = "v2ray-assets";
          # TODO use Loyalsoldier/geoip
          paths = with pkgs; [ v2ray-geoip v2ray-domain-list-community ];
        };
      in
      {
        V2RAY_LOCATION_ASSET = "${assets}/share/v2ray";
        XRAY_LOCATION_ASSET = "${assets}/share/v2ray";
        # # TODO split config file
        # V2RAY_LOCATION_CONFDIR = "";
        # XRAY_LOCATION_CONFDIR = "";
      };
    serviceConfig = {
      RestartSec = "10s";
      LogsDirectory = "v2ray";
      ExecStartPre = [
        "+${generate}/bin/v2ray.generate"
        "+${startPre}/bin/v2ray.startPre"
      ];
      ExecStop = [
        "+${stop}/bin/v2ray.stop"
      ];
    };

    # # https://github.com/kokobd/v2ray-network/blob/5546b61523dcf15933b50c219c352f56cca0b307/gateway/firewall.nix
    # preStart = ''

    # '';
    # preStop = ''

    # '';
  };

  boot.kernelModules = [
    "xt_TPROXY"
  ];

  /*
    https://github.com/springzfx/cgproxy/issues/10#issuecomment-673264483
    https://hackerl.github.io/2020/09/11/%E8%BD%AF%E8%B7%AF%E7%94%B1%E6%8A%98%E8%85%BE%E8%AE%B0%E5%BD%95%E4%BA%8C/
  */

  # # Options for routing
  # # maybe not loaded yet
  # boot.kernel.sysctl = {
  #   # Disable netfilter for bridges, for performance and security
  #   # Note that this means bridge-routed frames do not go through iptables
  #   # https://bugzilla.redhat.com/show_bug.cgi?id=512206#c0

  #   # for tproxy and docker bridge network
  #   "net.bridge.bridge-nf-call-ip6tables" = "0";
  #   "net.bridge.bridge-nf-call-iptables" = "0";
  #   "net.bridge.bridge-nf-call-arptables" = "0";
  # };

  services.logrotate.settings.v2ray = {
    enable = true;
    files = [ "/var/log/v2ray/*.log" ];
    frequency = "hourly";
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/usr/local/etc/v2ray"
    ];
  };
}
