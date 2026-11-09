{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.notifications;
  prefix = cfg.networkPrefix;
  subnet = "${prefix}.0/29";
  gateway = "${prefix}.1";
  apiAddress = "${prefix}.2";
  barkAddress = "${prefix}.3";
  images = import ../../nix/notifications.nix {
    inherit pkgs;
    inherit (config.security.pki) caBundle;
  };
  client = pkgs.writeShellScriptBin "site-notify" ''
    exec ${pkgs.python3}/bin/python3 ${../../scripts/notifications/client.py} "$@"
  '';
  hosts = pkgs.writeText "notification-hosts" ''
    127.0.0.1 localhost
    ${barkAddress} bark
    ${gateway} api.push.apple.com qyapi.weixin.qq.com oapi.dingtalk.com open.feishu.cn
  '';
  resolv = pkgs.writeText "notification-resolv.conf" "nameserver 127.0.0.1\noptions attempts:1 timeout:1\n";
  emptyChannels = pkgs.writeText "notification-channels.yaml" "urls: []\n";
  commonContainer = {
    networks = [ "site-notifications" ];
    volumes = [
      "${hosts}:/etc/hosts:ro"
      "${resolv}:/etc/resolv.conf:ro"
    ];
    extraOptions = [
      "--runtime=runsc"
      "--read-only"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      "--cpus=1"
      "--pids-limit=128"
      "--dns=127.0.0.1"
      "--log-driver=local"
      "--log-opt=max-size=5m"
      "--log-opt=max-file=2"
    ];
  };
  containerService = {
    wantedBy = [ "site-notification-network.service" ];
    requires = [
      "site-notification-network.service"
      "site-notification-secrets.service"
    ];
    after = [
      "site-notification-network.service"
      "site-notification-secrets.service"
    ];
    partOf = [
      "site-notification-secrets.service"
      "site-notification-network.service"
    ];
    restartTriggers = [ config.security.pki.caBundle ];
  };
  officialHosts = {
    apple = "api.push.apple.com";
    wecom = "qyapi.weixin.qq.com";
    dingtalk = "oapi.dingtalk.com";
    feishu = "open.feishu.cn";
  };
  routes = action: ''
    ip -4 rule ${action} pref 70 to ${subnet} lookup main protocol 99
    ip -4 rule ${action} pref 71 to ${subnet} unreachable protocol 99
  '';
in
{
  options.site.notifications = {
    enable = lib.mkEnableOption "local Apprise API and Bark notifications under gVisor";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Local address for the HTTP notification sending endpoint.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 19990;
      description = "TCP port for the HTTP notification sending endpoint.";
    };
    barkDeviceTokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-readable runtime file containing the Bark APNs device token.";
    };
    extraConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-readable native Apprise YAML containing additional tagged URLs.";
    };
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    backupChannels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "bark" ];
      description = "Apprise tags receiving backup, check, restore-test and maintenance results.";
    };
    networkPrefix = lib.mkOption {
      type = lib.types.strMatching "([0-9]{1,3}\\.){2}[0-9]{1,3}";
      default = "172.31.255";
      description = "First three IPv4 octets of a dedicated /29 internal Docker network.";
    };
  };
  config = lib.mkIf cfg.enable {
    virtualisation.docker.autoPrune.flags = [ "--filter=label!=org.nixos-config.service" ];
    networking.networkmanager.unmanaged = [ "interface-name:site-notify" ];
    assertions = [
      {
        assertion = config.virtualisation.docker.enable;
        message = "Notifications require Docker with the runsc runtime.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && !lib.hasPrefix "/nix/store/" path) (
          [ cfg.barkDeviceTokenFile ] ++ lib.optional (cfg.extraConfigFile != null) cfg.extraConfigFile
        );
        message = "Notification credentials must be runtime absolute paths outside the Nix store.";
      }
    ];
    users.groups.site-notifications.members = cfg.users;
    users.users.haproxy.extraGroups = [ "site-notifications" ];
    # nftables compiles numeric ownership matches before the target passwd exists.
    users.users.haproxy.uid = 64112;
    users.groups.haproxy.gid = 64112;
    environment.systemPackages = [
      client
      (pkgs.writeShellScriptBin "bark" ''
        exec ${client}/bin/site-notify bark "$@"
      '')
    ];
    virtualisation.oci-containers = {
      backend = "docker";
      containers = {
        site-apprise = lib.recursiveUpdate commonContainer {
          image = "site-apprise:local";
          imageStream = images.apiImage;
          volumes = commonContainer.volumes ++ [ "/run/site-notification-secrets/api:/run/credentials:ro" ];
          extraOptions = commonContainer.extraOptions ++ [
            "--ip=${apiAddress}"
            "--memory=512m"
            "--memory-swap=512m"
            "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=32m,uid=64110,gid=64110,mode=0700"
          ];
        };
        site-bark = lib.recursiveUpdate commonContainer {
          image = "site-bark:local";
          imageStream = images.barkImage;
          volumes = commonContainer.volumes ++ [ "/run/site-notification-secrets/bark:/run/credentials:ro" ];
          extraOptions = commonContainer.extraOptions ++ [
            "--ip=${barkAddress}"
            "--memory=256m"
            "--memory-swap=256m"
            "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=8m,uid=64111,gid=64111,mode=0700"
          ];
        };
      };
    };
    systemd.services = {
      site-notification-secrets = {
        description = "Prepare separate notification credential mounts";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-install-secrets.service" ];
        before = [
          "docker-site-apprise.service"
          "docker-site-bark.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "site-notification-secrets";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          ${pkgs.coreutils}/bin/install -d -m 0700 -o 64110 -g 64110 /run/site-notification-secrets/api
          ${pkgs.coreutils}/bin/install -d -m 0700 -o 64111 -g 64111 /run/site-notification-secrets/bark
          ${pkgs.coreutils}/bin/install -m 0400 -o 64111 -g 64111 ${lib.escapeShellArg cfg.barkDeviceTokenFile} /run/site-notification-secrets/bark/device-token
          ${pkgs.coreutils}/bin/install -m 0400 -o 64110 -g 64110 ${
            lib.escapeShellArg (
              if cfg.extraConfigFile == null then toString emptyChannels else cfg.extraConfigFile
            )
          } /run/site-notification-secrets/api/channels.yaml
        '';
      };
      site-notification-network = {
        description = "Private notification bridge and local service routes";
        wantedBy = [ "docker.service" ];
        requires = [
          "docker.service"
          "nftables.service"
        ];
        after = [
          "docker.service"
          "nftables.service"
        ];
        before = [ "haproxy.service" ];
        partOf = [ "docker.service" ];
        path = [
          pkgs.docker
          pkgs.iproute2
          pkgs.jq
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "site-notification-network";
        };
        script = ''
          if network=$(docker network inspect site-notifications 2>/dev/null); then
            owner=$(printf '%s' "$network" | jq -r '.[0].Labels["org.nixos-config.service"]')
            if [ "$owner" != site-notifications ]; then
              echo 'Docker network site-notifications belongs to another owner; choose an unused network.' >&2
              exit 1
            fi
            actual=$(printf '%s' "$network" | jq -r '.[0].IPAM.Config[0].Subnet')
            if [ "$actual" != ${lib.escapeShellArg subnet} ]; then
              docker network rm site-notifications
              network=
            fi
          else
            network=
          fi
          if [ -z "$network" ]; then
            docker network create --internal --subnet ${subnet} --gateway ${gateway} \
              --label org.nixos-config.service=site-notifications \
              --opt com.docker.network.bridge.name=site-notify site-notifications
          fi
          if ip -4 -j rule show | jq -e 'any(.[]; .priority == 70 or .priority == 71)' >/dev/null; then
            echo 'Notification route priorities are already in use.' >&2
            exit 1
          fi
          touch /run/site-notification-network/routes
          ${routes "add"}
        '';
        postStop = ''
          if [ -f /run/site-notification-network/routes ]; then
            for priority in 70 71; do
              if ip -4 -N -j rule show | jq -e --argjson p "$priority" 'any(.[]; .priority == $p and (.protocol | tostring) == "99")' >/dev/null; then
                ip -4 rule del pref "$priority" to ${subnet} protocol 99
              fi
            done
            rm /run/site-notification-network/routes
          fi
        '';
      };
      docker-site-apprise = containerService // {
        # Import the images in order; they share containerd content layers.
        after = containerService.after ++ [ "docker-site-bark.service" ];
      };
      docker-site-bark = containerService;
      haproxy = {
        wantedBy = [ "site-notification-network.service" ];
        partOf = [ "site-notification-network.service" ];
        requires = [ "site-notification-network.service" ];
        after = [ "site-notification-network.service" ];
        serviceConfig.RuntimeDirectory = [
          "haproxy"
          "site-notifications"
        ];
      };
    };
    services.haproxy = {
      enable = true;
      config = ''
        defaults
          mode tcp
          timeout connect 5s
          timeout client 30s
          timeout server 30s
        resolvers system
          parse-resolv-conf
          resolve_retries 2
          timeout resolve 1s
          timeout retry 1s
          hold valid 30s
        frontend notification_send
          bind /run/site-notifications/send.sock group site-notifications mode 660
          bind ${cfg.listenAddress}:${toString cfg.port}
          mode http
          option http-buffer-request
          http-request deny deny_status 404 unless { method POST } { path -m str /notify/local }
          http-request deny deny_status 413 if { req.body_size gt 8192 }
          http-request set-header Host localhost
          default_backend notification_api
        backend notification_api
          mode http
          server api ${apiAddress}:8000
        frontend notification_tls
          bind ${gateway}:443
          tcp-request inspect-delay 5s
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: host: ''
              acl sni_${name} req.ssl_sni -i ${host}
              acl source_${name} src ${if name == "apple" then barkAddress else apiAddress}
              tcp-request content accept if { req.ssl_hello_type 1 } sni_${name} source_${name}
            '') officialHosts
          )}
          tcp-request content reject if { req.ssl_hello_type 1 }
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: _: "use_backend notification_${name} if sni_${name} source_${name}"
            ) officialHosts
          )}
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: host: ''
            backend notification_${name}
              server official ${host}:443 resolvers system resolve-prefer ipv4 init-addr none
          '') officialHosts
        )}
      '';
    };
    networking = {
      nftables.enable = true;
      firewall.interfaces.site-notify.allowedTCPPorts = [ 443 ];
      nftables.tables.site-notifications = {
        family = "inet";
        content = ''
          chain output {
            type route hook output priority -140; policy accept;
            ip daddr ${apiAddress} tcp dport 8000 meta skuid ${toString config.users.users.haproxy.uid} ct mark set 0xf41 meta mark set 0x6d6f6c65 accept
            ip daddr ${subnet} ct state established,related accept
            ip daddr ${subnet} drop
          }
          chain input {
            type filter hook input priority -10; policy accept;
            iifname "site-notify" ip saddr { ${apiAddress}, ${barkAddress} } ip daddr ${gateway} tcp dport 443 ct mark set 0xf41 accept
            iifname "site-notify" ct state established,related ct mark set 0xf41 accept
            iifname "site-notify" drop
          }
          chain forward {
            type filter hook forward priority -200; policy accept;
            # Bridge netfilter also visits the host's Internet firewall. Keep
            # this one local backend connection independent of tunnel capture.
            iifname "site-notify" oifname "site-notify" ip saddr ${apiAddress} ip daddr ${barkAddress} tcp dport 8080 ct mark set 0xf41 accept
            iifname "site-notify" oifname "site-notify" ip saddr ${barkAddress} ip daddr ${apiAddress} tcp sport 8080 ct state established ct mark set 0xf41 accept
            iifname "site-notify" oifname != "site-notify" drop
            oifname "site-notify" iifname != "site-notify" drop
          }
        '';
      };
      nftables.tables.site-notification-bridge = {
        family = "bridge";
        content = ''
          chain forward {
            type filter hook forward priority -200; policy accept;
            ibrname "site-notify" ether type arp accept
            ibrname "site-notify" ip saddr ${apiAddress} ip daddr ${barkAddress} tcp dport 8080 accept
            ibrname "site-notify" ip saddr ${barkAddress} ip daddr ${apiAddress} tcp sport 8080 ct state established accept
            ibrname "site-notify" drop
            obrname "site-notify" drop
          }
        '';
      };
    };
  };
}
