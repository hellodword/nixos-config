{ lib, ... }:
{
  site.network = {
    ipv6.enable = lib.mkDefault false;
    localAccess.enable = lib.mkDefault true;
    dns.enable = lib.mkDefault true;
    singBox.enable = lib.mkDefault true;
    lockdown.enable = lib.mkDefault true;
    purposeRouting.enable = lib.mkDefault true;
  };
}
