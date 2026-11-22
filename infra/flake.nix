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
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      lib = {
        cache = import ./nix/cache.nix;
        testing = import ./nix/testing.nix;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          orancPkg = oranc.packages.${system}.default;
        in
        {
          oranc = orancPkg;
          ci-tools = import ./nix/ci-tools.nix {
            inherit pkgs;
            oranc = orancPkg;
            root = ./.;
          };
        }
      );

      apps = forAllSystems (system: {
        ci = {
          type = "app";
          program = "${self.packages.${system}.ci-tools}/bin/nix-ci";
        };
      });
    };
}
