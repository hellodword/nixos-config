{
  config,
  lib,
  pkgs,
  ...
}:
let
  enabled = config.virtualisation.docker.enable && (config.site.network.dns.enable or false);
  lockdown = config.site.network.lockdown.enable or false;
  resolver = "169.254.53.53";
  command = "${pkgs.python3}/bin/python3 ${../../scripts/network/docker_network.py}";
in
{
  config = lib.mkIf enabled {
    # A host-owned address stays constant when Docker allocates a new subnet.
    networking.interfaces.lo.ipv4.addresses = [
      {
        address = resolver;
        prefixLength = 32;
      }
    ];
    services.resolved.settings.Resolve.DNSStubListenerExtra = [ resolver ];
    virtualisation.docker.daemon.settings.dns = [ resolver ];
    networking.nftables = {
      enable = true;
      flushRuleset = false;
      tables.site-container-dns = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority -20; policy accept;
            iifname "lo" accept
            ip daddr ${resolver} meta l4proto { tcp, udp } th dport 53 ct mark 0xf41 accept
            ip daddr ${resolver} drop
          }
        '';
      };
    };
    networking.firewall.extraInputRules = ''
      ip daddr ${resolver} meta l4proto { tcp, udp } th dport 53 ct mark 0xf41 accept
    '';
    systemd.services.docker.after = [ "network-addresses-lo.service" ];
    systemd.services.site-container-network = {
      description = "Docker bridge DNS and local routing";
      wantedBy = [ "docker.service" ];
      requires = [
        "docker.service"
        "nftables.service"
        "systemd-resolved.service"
      ];
      after = [
        "docker.service"
        "nftables.service"
        "systemd-resolved.service"
      ];
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
        ExecStart = "${command} run --resolver ${resolver}" + lib.optionalString lockdown " --lockdown";
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
