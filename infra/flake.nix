{
  description = "Shared Nix infrastructure, binary cache policies, CI runner, and VM test helpers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oranc.url = "github:linyinfeng/oranc";
  };

  outputs =
    {
      self,
      nixpkgs,
      oranc,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      orancPkg = oranc.packages.${system}.default;
    in
    {
      lib = {
        cache = import ./nix/cache.nix;
        testing = import ./nix/testing.nix;
      };

      packages.${system} = {
        oranc = orancPkg;
        ci-tools = import ./nix/ci-tools.nix {
          inherit pkgs;
          oranc = orancPkg;
          root = ./.;
        };
      };

      apps.${system}.ci = {
        type = "app";
        program = "${self.packages.${system}.ci-tools}/bin/nix-ci";
      };
    };
}
