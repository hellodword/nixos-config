{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.site.network;
  mullvad = import ../../nix/mullvad.nix { inherit pkgs; };
  command = "${pkgs.python3}/bin/python3 ${../../scripts/network}/lockdown.py";
  controlEnvironment = {
    MULLVAD_SETTINGS_DIR = "/var/lib/site-network/mullvad";
    MULLVAD_CACHE_DIR = "/var/lib/site-network/mullvad-cache";
    MULLVAD_RPC_SOCKET_PATH = "/run/site-network-control/mullvad.sock";
  };
  tools = [
    pkgs.iproute2
    pkgs.wireguard-tools
    pkgs.nftables
    pkgs.procps
    mullvad
  ];
  control = pkgs.writeShellApplication {
    name = "network-lockdown";
    runtimeInputs = [
      mullvad
      pkgs.systemd
    ];
    text = ''
      export MULLVAD_RPC_SOCKET_PATH=${controlEnvironment.MULLVAD_RPC_SOCKET_PATH}
      case "''${1:-status}" in
        status) mullvad status; mullvad lockdown-mode get ;;
        disconnect) mullvad lockdown-mode set on; systemctl stop sing-box.service; mullvad disconnect ;;
        connect) mullvad lockdown-mode set on; systemctl restart site-network-connect.service ;;
        *) echo 'Usage: sudo network-lockdown [status|disconnect|connect]' >&2; exit 2 ;;
      esac
    '';
  };
in
{
  options.site.network.lockdown.enable = lib.mkEnableOption "protected transparent networking";
  config = lib.mkIf cfg.lockdown.enable {
    networking.firewall = {
      enable = true;
      checkReversePath = "loose";
    };
    networking.nftables = {
      enable = true;
      flushRuleset = false;
    };
    assertions = [
      {
        assertion = cfg.dns.enable && cfg.singBox.enable;
        message = "Lockdown requires DNS and sing-box.";
      }
    ];
    services.mullvad-vpn = {
      enable = true;
      package = mullvad;
      enableEarlyBootBlocking = true;
      enableExcludeWrapper = false;
      gui.enable = false;
    };
    boot.kernelModules = [
      "wireguard"
    ];
    networking.nftables.tables.site-source-guard = {
      family = "inet";
      content = ''
        chain postrouting {
          type filter hook postrouting priority 200; policy accept;
          oifname != { "lo", "wg0-mullvad" } ip saddr 10.67.0.2 counter drop
          oifname != { "lo", "wg0-mullvad" } ip6 saddr fd66:105::2 counter drop
        }
      '';
    };
    systemd.services = {
      mullvad-early-boot-blocking.environment = controlEnvironment;
      mullvad-daemon = {
        environment = controlEnvironment;
        requires = [ "site-network-prepare.service" ];
        after = [ "site-network-prepare.service" ];
        serviceConfig = {
          LogRateLimitIntervalSec = 0;
          RuntimeDirectory = "site-network-control";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
        };
      };
      site-network-prepare = {
        description = "Create local peer identity and seed protected first-start settings";
        after = [ "local-fs.target" ];
        before = [ "mullvad-daemon.service" ];
        path = tools;
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "site-network";
          StateDirectoryMode = "0700";
          ExecStart = "${command} prepare";
          UMask = "0077";
        };
      };
      site-network-routing = {
        description = "Capture ordinary traffic in the protected tunnel";
        wantedBy = [ "multi-user.target" ];
        requires = [ "site-network-prepare.service" ];
        after = [
          "mullvad-early-boot-blocking.service"
          "site-network-prepare.service"
          "nftables.service"
        ];
        before = [ "sing-box.service" ];
        path = tools;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "site-network-routing";
          RuntimeDirectoryMode = "0700";
          ExecStart = "${command} start";
          ExecStopPost = "${command} stop";
          UMask = "0077";
        };
      };
      site-network-connect = {
        description = "Connect Mullvad to the local sing-box peer";
        wantedBy = [ "multi-user.target" ];
        # Configure the peer even while proxy credentials are being supplied.
        # Mullvad retries the protected tunnel until the receiver is ready.
        wants = [ "sing-box.service" ];
        requires = [ "mullvad-daemon.service" ];
        after = [
          "mullvad-daemon.service"
          "sing-box.service"
        ];
        environment = controlEnvironment;
        path = tools;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${command} connect";
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0077";
        };
      };
      site-network-underlay = {
        description = "Refresh excluded proxy bindings on physical route/address changes";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "mullvad-daemon.service"
        ];
        environment = controlEnvironment;
        path = [
          pkgs.iproute2
          pkgs.systemd
          mullvad
        ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/network}/underlay.py";
          RuntimeDirectory = "site-network-underlay";
          RuntimeDirectoryMode = "0700";
          # A coordinated policy update pauses this observer before restarting
          # the proxy. Keep its last binding available during that short pause.
          # /run is still cleared at boot; the observer refreshes it on start.
          RuntimeDirectoryPreserve = "yes";
          Restart = "on-failure";
          RestartSec = "2s";
          UMask = "0077";
        };
      };
    };
    environment.systemPackages = [ control ];
  };
}
