{ ... }:
{
  imports = [
    ../core/storage.nix
    ./tailscale.nix
    ./local-access.nix
    ./logging.nix
    ./policy.nix
    ./dns.nix
    ./sing-box.nix
    ./lockdown.nix
  ];
}
