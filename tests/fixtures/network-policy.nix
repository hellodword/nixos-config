{ lib }:
let
  policy = import ../../lib/network-policy.nix { inherit lib; };
in
{
  combined = policy {
    lockdown = false;
    mixedPort = 18080;
  };
  standalone = policy {
    dns = false;
    lockdown = false;
    mixedPort = 18080;
  };
}
