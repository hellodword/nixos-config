{ config, lib, ... }:
let
  ports = lib.unique (lib.sort lib.lessThan config.site.reservedPorts);
in
{
  options.site.reservedPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "Local ports excluded from kernel ephemeral TCP/UDP port allocation.";
  };
  config = lib.mkIf (ports != [ ]) {
    boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" = lib.concatMapStringsSep "," toString ports;
  };
}
