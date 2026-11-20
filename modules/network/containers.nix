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
  ipv6Pending = config.systemd.paths.site-network-ipv6-reconcile.pathConfig.PathExists or null;
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
      wants = lib.optional lockdown "site-network-exclude-dns.service";
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
      ];
      serviceConfig = (import ../../lib/service-hardening.nix) // {
        DynamicUser = false;
        Type = "notify";
        ReadWritePaths = lib.optional (ipv6Pending != null) (builtins.dirOf ipv6Pending);
        ExecStart =
          "${command} run"
          + lib.optionalString (ipv6Pending != null) " --ipv6-pending ${lib.escapeShellArg ipv6Pending}"
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
