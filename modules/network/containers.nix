{
  config,
  lib,
  pkgs,
  ...
}:
let
  enabled = config.virtualisation.docker.enable;
  dns = config.site.network.dns.enable or false;
  lockdown = config.site.network.lockdown.enable or false;
  cfg = config.site.network.containers;
  command = "${pkgs.python3}/bin/python3 ${../../scripts/network}/docker_network.py";
in
{
  options.site.network.containers = {
    hostTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Host TCP ports available through the default Docker bridge gateway.";
    };
    hostUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Host UDP ports available through the default Docker bridge gateway.";
    };
  };
  config = lib.mkIf enabled {
    virtualisation.docker.daemon.settings.dns = lib.mkIf dns [ config.site.network.dns.ingressIPv4 ];
    networking.nftables = {
      enable = true;
      flushRuleset = false;
    };
    networking.firewall.extraInputRules = ''
      # Set only in INPUT for the discovered default bridge -> gateway tuple.
      meta mark 0x646f636b ct mark 0xf41 accept
    '';
    systemd.services.docker.after = lib.optional dns "network-addresses-lo.service";
    systemd.services.site-container-network = {
      description = "Docker bridge DNS and local routing";
      wantedBy = [ "docker.service" ];
      requires = [
        "docker.service"
        "nftables.service"
      ]
      ++ lib.optional dns "systemd-resolved.service";
      after = [
        "docker.service"
        "nftables.service"
      ]
      ++ lib.optional dns "systemd-resolved.service";
      partOf = [
        "docker.service"
        "nftables.service"
      ];
      path = [
        config.virtualisation.docker.package
        pkgs.iproute2
        pkgs.nftables
        pkgs.systemd
      ];
      serviceConfig = (import ../../lib/service-hardening.nix) // {
        DynamicUser = false;
        Type = "notify";
        ExecStart =
          "${command} run"
          + lib.optionalString dns " --dns"
          + lib.optionalString lockdown " --lockdown"
          + lib.concatMapStrings (port: " --host-tcp-port ${toString port}") cfg.hostTCPPorts
          + lib.concatMapStrings (port: " --host-udp-port ${toString port}") cfg.hostUDPPorts;
        ExecStopPost = "${command} stop";
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStartSec = "45s";
        TimeoutStopSec = "15s";
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
