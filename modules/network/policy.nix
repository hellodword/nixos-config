{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  enabled = cfg.dns.enable || cfg.singBox.enable;
  json = pkgs.formats.json { };
  scripts = ../../scripts/network;
  effective = lib.recursiveUpdate options.site.network.dnsPolicy.default cfg.dnsPolicy;
  policy = json.generate "domain-policy.json" (
    effective
    // {
      routeFragments = cfg.routeFragments;
      connectionFragments = cfg.connectionFragments;
      jsoncTool = "${pkgs.hujsonfmt}/bin/hujsonfmt";
      regexTool = "${import ../../nix/route-regex.nix { inherit pkgs; }}/bin/route-regex";
      ruleSetTool = "${pkgs.sing-box}/bin/sing-box";
      tailnetUpstream =
        if config.services.tailscale.enable then
          {
            address = "100.100.100.100";
            port = 53;
          }
        else
          null;
      caStore = effective.caStore or "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      tunnelGroups =
        if cfg.lockdown.enable then
          [
            "cn"
            "global"
          ]
        else
          lib.optional cfg.singBox.enable "global";
    }
  );
  base = json.generate "network-transport.json" (
    lib.recursiveUpdate
      (import ../../lib/network-policy.nix { inherit lib; } {
        inherit (cfg) directNetworks blockedNetworks ipRuleSets;
        dns = cfg.dns.enable;
        fakeIP = cfg.dns.fakeIP.enable;
        lockdown = cfg.lockdown.enable;
        tailscale = config.services.tailscale.enable;
        dnsPort = effective.frontPort or 5300;
        bootstrapPort = effective.bootstrapPort or 5301;
      })
      (
        lib.optionalAttrs cfg.clash.enable {
          experimental = {
            clash_api.external_controller = "127.0.0.1:${toString cfg.clash.port}";
          };
        }
      )
  );
  bundle = pkgs.runCommand "network-policy" { nativeBuildInputs = [ pkgs.hujsonfmt ]; } ''
    mkdir -p $out
    ${lib.optionalString cfg.dns.enable ''
      ${pkgs.python3}/bin/python3 ${scripts}/dns_policy.py --policy ${policy} --output $out
      ${pkgs.dnsdist}/bin/dnsdist --check-config -C $out/dnsdist.conf
    ''}
    ${lib.optionalString cfg.singBox.enable ''
      ${pkgs.python3}/bin/python3 ${scripts}/assemble.py --base ${base} --policy ${policy} \
        ${lib.optionalString cfg.dns.enable "--transports $out/transports.json"} --output $out/network.json
    ''}
  '';
  runtimeRoot = "/run/site-network-policy";
  rulesState = "/var/lib/site-network-rules";
  consumers =
    lib.optionals cfg.dns.enable [
      "site-dns.service"
      "site-dns-race-cn.service"
      "site-dns-race-global.service"
    ]
    ++ lib.optional cfg.singBox.enable "sing-box.service";
  flags = ''
    --policy ${policy} --root ${runtimeRoot} --group site-network-policy \
    ${
      lib.optionalString (
        cfg.runtimeRouteDirectory != null
      ) "--fragments ${lib.escapeShellArg cfg.runtimeRouteDirectory}"
    } \
    ${
      lib.optionalString (
        cfg.runtimeConnectionDirectory != null
      ) "--connections ${lib.escapeShellArg cfg.runtimeConnectionDirectory}"
    } \
    ${lib.optionalString cfg.dns.enable "--dnsdist ${pkgs.dnsdist}/bin/dnsdist"} \
    ${
      lib.optionalString (
        cfg.dns.fakeIP.enable && cfg.dns.fakeIP.excludeFile != null
      ) "--fakeip-exclude ${lib.escapeShellArg cfg.dns.fakeIP.excludeFile}"
    } \
    ${lib.optionalString cfg.singBox.enable "--base ${base} --provider ${lib.escapeShellArg cfg.providerFile} --sing-box ${pkgs.sing-box}/bin/sing-box"} \
    ${lib.optionalString config.services.tailscale.enable "--tailscale"} \
    ${lib.optionalString cfg.lockdown.enable "--watch-underlay --wireguard-key /var/lib/site-network/gateway.key --wireguard-peer /var/lib/site-network/client.pub"} \
    --curl ${pkgs.curl}/bin/curl ${lib.optionalString cfg.singBox.enable "--download-proxy socks5h://127.0.0.1:10800"}
  '';
  prepareCommand = pkgs.writeShellScript "prepare-network-policy" ''
    set -eu
    stage="$1"
    bootstrap=()
    family=()
    rules=()
    if [ "$3" = ipv4 ]; then family=(--ipv4-only); fi
    if [ "$2" = bootstrap ]; then bootstrap=(--bootstrap); fi
    if [ -n "$4" ]; then rules=(--rules-directory "$4"); fi
    exec ${pkgs.systemd}/bin/systemd-run --quiet --wait --pipe --collect \
      --service-type=exec \
      --property=RootDirectory=${runtimeRoot}/sandbox \
      --property=MountAPIVFS=yes \
      --property=BindReadOnlyPaths=${
        lib.escapeShellArg (
          lib.concatStringsSep " " (
            [
              "/nix/store"
              "/etc/passwd"
              "/etc/group"
              "-${rulesState}"
            ]
            ++ cfg.policyReadOnlyPaths
            ++ lib.optional (cfg.runtimeRouteDirectory != null) "-${cfg.runtimeRouteDirectory}"
            ++ lib.optional (cfg.runtimeConnectionDirectory != null) "-${cfg.runtimeConnectionDirectory}"
            ++ lib.optional cfg.singBox.enable "-${cfg.providerFile}"
            ++ lib.optional (
              cfg.dns.fakeIP.enable && cfg.dns.fakeIP.excludeFile != null
            ) cfg.dns.fakeIP.excludeFile
            ++ lib.optionals cfg.lockdown.enable [
              "/var/lib/site-network/gateway.key"
              "/var/lib/site-network/client.pub"
            ]
          )
        )
      } \
      --property="BindPaths=$stage" --property="ReadWritePaths=$stage" \
      --property=ProtectSystem=strict --property=ProtectHome=yes \
      --property=PrivateTmp=yes --property=PrivateDevices=yes --property=PrivateNetwork=yes \
      --property=NoNewPrivileges=yes --property=CapabilityBoundingSet= \
      --property=RestrictNamespaces=yes --property=RestrictSUIDSGID=yes \
      --property=ProtectKernelTunables=yes --property=ProtectKernelModules=yes \
      --property=ProtectControlGroups=yes --property=LockPersonality=yes \
      --property=SystemCallArchitectures=native --property=TimeoutStartSec=5min \
      --setenv=PATH=${lib.makeBinPath [ pkgs.hujsonfmt ]} \
      ${pkgs.python3}/bin/python3 ${scripts}/runtime_policy.py prepare --stage "$stage" "''${bootstrap[@]}" "''${family[@]}" "''${rules[@]}" ${flags}
  '';
  runtimeCommand = pkgs.writeShellScript "network-policy-command" ''
    set -eu
    export LC_ALL=C
    export PATH=${
      lib.makeBinPath (
        [
          pkgs.systemd
          pkgs.iproute2
          pkgs.nftables
          pkgs.networkmanager
        ]
        ++ lib.optional cfg.lockdown.enable config.services.mullvad-vpn.package
      )
    }:$PATH
    ${lib.optionalString cfg.lockdown.enable "export MULLVAD_RPC_SOCKET_PATH=/run/site-network-control/mullvad.sock"}
    if [ "''${1:-}" != rules-status ]; then
      ${pkgs.coreutils}/bin/install -d -m 0750 -g site-network-policy ${runtimeRoot}
      ${pkgs.coreutils}/bin/install -d -m 0755 ${runtimeRoot}/sandbox
    fi
    exec ${pkgs.python3}/bin/python3 ${scripts}/runtime_policy.py "$@" --prepare-command ${prepareCommand} ${flags}
  '';
  ruleUpdater = arguments: {
    description = "Download and validate shared domain rules";
    after = consumers ++ [
      "site-network-policy.service"
      "network-online.target"
    ];
    requires = [ "site-network-policy.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${runtimeCommand} update-rules${arguments}";
      StateDirectory = "site-network-rules";
      StateDirectoryMode = "0700";
      UMask = "0077";
      TimeoutStartSec = "20min";
    };
  };

in
{
  options.site.network = {
    ipv6.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Boot-time IPv6 mode; network-ipv6 can override it until reboot.";
    };
    dnsPolicy = lib.mkOption {
      type = json.type;
      description = "DNS listeners, encrypted upstream groups and ECS settings.";
      default = {
        groups = {
          cn.upstreams = [
            {
              protocol = "tls";
              address = "223.5.5.5";
              port = 853;
              serverName = "dns.alidns.com";
            }
            {
              protocol = "https";
              address = "223.6.6.6";
              port = 443;
              serverName = "dns.alidns.com";
              path = "/dns-query";
            }
          ];
          global.upstreams = [
            {
              protocol = "tls";
              address = "8.8.8.8";
              port = 853;
              serverName = "dns.google";
            }
            {
              protocol = "https";
              address = "1.1.1.1";
              port = 443;
              serverName = "cloudflare-dns.com";
              path = "/dns-query";
            }
          ];
        };
      };
    };
    routeFragments = lib.mkOption {
      type = lib.types.attrsOf json.type;
      default = { };
      description = "Filename-keyed sing-box route fragments, applied in bytewise filename order.";
    };
    connectionFragments = lib.mkOption {
      type = lib.types.attrsOf json.type;
      default = { };
      description = "Native sing-box route fragments, ordered together with shared domain fragments by filename.";
    };
    runtimeConnectionDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Persistent connection.d fragments for sing-box; same-name local files replace declared fragments.";
    };
    policyReadOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional absolute paths visible read-only during sandboxed policy validation, such as local rule sets or TLS CA files.";
    };
    generatedPolicy = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
    };
    runtimeRouteDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Directory of persistent route fragments; local files replace declarative files with the same name.";
    };
    activePolicy = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
    };
  };
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion =
          cfg.runtimeRouteDirectory == null || !lib.hasPrefix "/nix/store/" cfg.runtimeRouteDirectory;
        message = "Runtime route fragments must use a writable directory outside the Nix store.";
      }
    ];
    site.network.routeFragments = {
      "00-defaults.json" = lib.mkDefault { final = "proxy"; };
      "10-tailnet.json" = lib.mkDefault {
        rules = [
          {
            domain_suffix = [
              "ts.net"
              "0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa"
            ]
            ++ map (n: "${toString n}.100.in-addr.arpa") (lib.range 64 127);
            action = "route";
            outbound = if config.services.tailscale.enable then "tailnet" else "private";
          }
        ];
      };
      "15-tailscale-services.json" = lib.mkDefault {
        rules = [
          {
            domain_suffix = [
              "tailscale.com"
              "tailscale.io"
            ];
            action = "route";
            outbound = "direct";
          }
        ];
      };
      "20-private.json" = lib.mkDefault {
        rules = [
          {
            domain_suffix = [
              "lan"
              "local"
              "localhost"
              "home.arpa"
              "invalid"
              "test"
              "onion"
              "10.in-addr.arpa"
              "127.in-addr.arpa"
              "0.in-addr.arpa"
              "168.192.in-addr.arpa"
              "254.169.in-addr.arpa"
              "d.f.ip6.arpa"
              "c.f.ip6.arpa"
              "8.e.f.ip6.arpa"
              "9.e.f.ip6.arpa"
              "a.e.f.ip6.arpa"
              "b.e.f.ip6.arpa"
            ]
            ++ map (n: "${toString n}.172.in-addr.arpa") (lib.range 16 31);
            action = "route";
            outbound = "private";
          }
        ];
      };
      "90-cn.json" = lib.mkDefault {
        rules = [
          {
            domain_suffix = [ "cn" ];
            action = "route";
            outbound = "direct";
          }
        ];
      };
    };
    site.network.generatedPolicy = bundle;
    site.network.activePolicy = "${runtimeRoot}/current";
    environment.etc."site-network/ipv6.json".source = json.generate "network-ipv6.json" {
      inherit (cfg.ipv6) enable;
      dnsIngress = if cfg.dns.enable then cfg.dns.ingressIPv6 else null;
    };
    users.groups.site-network-policy = { };
    networking.nftables.enable = true;
    networking.nftables.flushRuleset = false;
    systemd.services.site-network-policy = {
      description = "Prepare enabled network policy consumers";
      before = consumers;
      requires = [
        "site-network-address-family.service"
      ]
      ++ lib.optional cfg.lockdown.enable "site-network-prepare.service";
      after = [
        "site-network-address-family.service"
      ]
      ++ lib.optional cfg.lockdown.enable "site-network-prepare.service";
      path = [ pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runtimeCommand} bootstrap";
        RuntimeDirectory = "site-network-policy";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes";
        Group = "site-network-policy";
        UMask = "0027";
      };
    };
    systemd.services.site-network-rules-update = ruleUpdater "";
    systemd.services.site-network-rules-schedule = ruleUpdater " --if-due";
    systemd.timers.site-network-rules-schedule = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "1h";
      };
    };
    systemd.services."site-network-rules-apply@" = {
      description = "Apply confirmed shared domain rules";
      requires = [ "site-network-policy.service" ];
      after = [ "site-network-policy.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${runtimeCommand} apply-rules --generation %i";
        TimeoutStartSec = "10min";
      };
    };
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "network-policy";
        runtimeInputs = [ pkgs.systemd ];
        text = ''exec ${runtimeCommand} "$@"'';
      })
      (pkgs.writeShellApplication {
        name = "network-ipv6";
        text = ''
          if [ "$#" -gt 1 ]; then
            echo 'Usage: sudo network-ipv6 [on|off|status]' >&2
            exit 2
          fi
          case "''${1:-status}" in
            on|off|status) exec ${runtimeCommand} ipv6 "''${1:-status}" ;;
            -h|--help) echo 'Usage: sudo network-ipv6 [on|off|status]' ;;
            *) echo 'Usage: sudo network-ipv6 [on|off|status]' >&2; exit 2 ;;
          esac
        '';
      })
    ];
    systemd.services.site-network-address-family = {
      description = "Initialize the host network address family";
      wantedBy = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      requires = [ "nftables.service" ];
      after = [ "nftables.service" ];
      before = [
        "network-pre.target"
        "site-network-routing.service"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runtimeCommand} initialize";
      };
    };
    systemd.services.site-network-ipv6-reconcile = {
      description = "Apply the current address family to connected interfaces";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${runtimeCommand} reconcile";
      };
    };
    networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
      {
        source = pkgs.writeShellScript "network-address-family" ''
          case "$2" in
            up|dhcp6-change|connectivity-change)
              ${pkgs.systemd}/bin/systemctl --no-block start site-network-ipv6-reconcile.service
              ;;
          esac
        '';
      }
    ];
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", TAG+="systemd", ENV{SYSTEMD_WANTS}+="site-network-ipv6-reconcile.service"
    '';
    environment.etc."gai.conf".text = ''
      precedence ::1/128       50
      precedence ::/0          40
      precedence 2002::/16     30
      precedence ::/96         20
      precedence ::ffff:0:0/96 100
    '';
  };
}
