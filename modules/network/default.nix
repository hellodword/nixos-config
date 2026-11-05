{ ... }:
{
  imports = [
    ../core/storage.nix
    ./tailscale.nix
    ./logging.nix
    ./policy.nix
    ./dns.nix
    ./sing-box.nix
    ./lockdown.nix
  ];
}
