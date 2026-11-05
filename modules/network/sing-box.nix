{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  json = pkgs.formats.json { };
  render = pkgs.writeShellScript "render-split-network" ''
    umask 077
    export PATH=${lib.makeBinPath [ pkgs.hujsonfmt ]}:$PATH
    exec ${pkgs.python3}/bin/python3 ${../../scripts/network}/render.py \
      --template ${cfg.activePolicy}/network.json --provider "$CREDENTIALS_DIRECTORY/provider" \
      --output /run/sing-box/config.json --checker ${lib.getExe pkgs.sing-box} \
      ${lib.optionalString cfg.clash.enable "--clash-secret \"$CREDENTIALS_DIRECTORY/clash-secret\""} \
      ${lib.optionalString cfg.lockdown.enable "--underlay \"$CREDENTIALS_DIRECTORY/underlay\" --wireguard-key \"$CREDENTIALS_DIRECTORY/wireguard-key\" --wireguard-peer \"$CREDENTIALS_DIRECTORY/wireguard-peer\""}
  '';
in
{
  options.site.network = {
    singBox.enable = lib.mkEnableOption "explicit proxy and connection routing";
    clash = {
      enable = lib.mkEnableOption "authenticated loopback Clash API and persistent proxy selection";
      port = lib.mkOption {
        type = lib.types.port;
        default = 9090;
      };
      secretFile = lib.mkOption {
        type = lib.types.str;
        default = "${config.site.storage.persistRoot}/usr/local/etc/sing-box/clash-secret";
        description = "Runtime file containing the Clash API bearer token.";
      };
    };
    providerFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.site.storage.persistRoot}/usr/local/etc/sing-box/outbounds.json";
      description = "Runtime JSONC containing native concrete outbounds and endpoints.";
    };
    directNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Direct IP ranges in the ordered 97-direct-ip.json connection fragment.";
    };
    blockedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "IP networks denied before domain fallbacks.";
    };
    ipRuleSets = lib.mkOption {
      type = lib.types.listOf json.type;
      default = [ ];
      description = "Local rule sets in the ordered 98-geoip.json connection fragment.";
    };
  };
  config = lib.mkIf cfg.singBox.enable {
    assertions = [
      {
        assertion = !lib.hasPrefix "/nix/store/" cfg.providerFile;
        message = "Proxy credentials must be loaded at runtime.";
      }
      {
        assertion = lib.all (r: r.type or "" == "local") cfg.ipRuleSets;
        message = "Routing lists must be pinned local build inputs.";
      }
    ];
    users.users.sing-box = {
      isSystemUser = true;
      group = "sing-box";
    };
    users.groups.sing-box = { };
    systemd.services.sing-box = {
      restartTriggers = [ config.security.pki.caBundle ];
      description = "Shared TCP/UDP splitting and explicit DNS transport tunnels";
      wantedBy = [ "multi-user.target" ];
      wants = lib.optional cfg.dns.enable "site-dns.service";
      after = [
        "network.target"
      ]
      ++ lib.optional cfg.dns.enable "site-dns.service"
      ++ [ "site-network-policy.service" ]
      ++ lib.optionals cfg.lockdown.enable [
        "site-network-routing.service"
        "mullvad-daemon.service"
      ];
      partOf = [ "site-network-policy.service" ];
      requires = [
        "site-network-policy.service"
      ]
      ++ lib.optionals cfg.lockdown.enable [
        "site-network-routing.service"
        "mullvad-daemon.service"
      ];
      serviceConfig = import ../../lib/service-hardening.nix // {
        DynamicUser = false;
        MemoryDenyWriteExecute = true;
        User = "sing-box";
        Group = "sing-box";
        LogRateLimitIntervalSec = 0;
        SupplementaryGroups = [ "site-network-policy" ];
        LoadCredential = [
          "provider:${cfg.activePolicy}/provider.json"
        ]
        ++ lib.optional cfg.clash.enable "clash-secret:${cfg.clash.secretFile}"
        ++ lib.optionals cfg.lockdown.enable [
          "wireguard-key:/var/lib/site-network/gateway.key"
          "wireguard-peer:/var/lib/site-network/client.pub"
          "underlay:/run/site-network-underlay/underlay.json"
        ];
        RuntimeDirectory = "sing-box";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "sing-box";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/sing-box";
        ExecStartPre = render;
        ExecStart =
          # Only exclusion setup runs as root. Drop to the service identity and
          # remove setup capabilities before starting the network engine.
          (lib.optionalString cfg.lockdown.enable (
            "!${config.services.mullvad-vpn.package}/bin/mullvad-exclude "
            + "${pkgs.python3}/bin/python3 ${../../scripts/network/run_excluded.py} "
            + "${pkgs.util-linux}/bin/setpriv --reuid=sing-box --regid=sing-box --init-groups "
            + "--inh-caps=-all,+net_admin,+net_raw --ambient-caps=-all,+net_admin,+net_raw "
            + "--bounding-set=-setuid,-setgid,-setpcap "
          ))
          + "${lib.getExe pkgs.sing-box} run -D /var/lib/sing-box -c /run/sing-box/config.json";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        CapabilityBoundingSet = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ]
        ++ lib.optionals cfg.lockdown.enable [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_SETPCAP"
        ];
        AmbientCapabilities = [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];
        SystemCallFilter = [
          "@system-service"
        ]
        ++ lib.optionals cfg.lockdown.enable [
          "@setuid"
          "capset"
        ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        # Official mullvad-exclude writes its dedicated cgroup before exec.
        ProtectControlGroups = !cfg.lockdown.enable;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        DevicePolicy = "closed";
        BindPaths = [ "/dev/net/tun" ];
        DeviceAllow = [ "/dev/net/tun rw" ];
      };
    };
    environment.systemPackages = [ pkgs.sing-box ];
  };
}
