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
  localAccess = config.site.network.localAccess.enable or false;
  command = "${pkgs.python3}/bin/python3 ${../../scripts/network}/docker_network.py";
in
{
  config = lib.mkIf enabled {
    virtualisation.docker.daemon.settings.dns = lib.mkIf dns [ config.site.network.dns.ingressIPv4 ];
    networking.nftables = {
      enable = true;
      flushRuleset = false;
    };
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
          + lib.optionalString localAccess " --local-access";
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
