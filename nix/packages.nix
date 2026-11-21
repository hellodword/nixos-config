{
  pkgs,
  inputs,
  system ? pkgs.stdenv.hostPlatform.system,
}:
let
  remote = inputs.nixpkgs-remote.legacyPackages.${system};
in
{
  oranc = inputs.infra.packages.${system}.oranc;
  wrangler = import ./wrangler.nix { pkgs = remote; };
}
