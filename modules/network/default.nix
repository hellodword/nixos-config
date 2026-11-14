{ ... }:
{
  imports = [
    ../core/storage.nix
    ./tailscale.nix
    ./local-access.nix
    ./logging.nix
    ./policy.nix
    ./purpose-routing.nix
    ./dns.nix
    ./sing-box.nix
    ./lockdown.nix
  ];
}
