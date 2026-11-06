{
  description = "Native NixOS laptop, with explicit state and network policy";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    # Keep installation-sensitive revisions until a separately validated upgrade.
    disko.url = "github:nix-community/disko/5a2dc95464080764b9ca1b82b5d6d981157522be";
    impermanence.url = "github:nix-community/impermanence/fa627f4c8b8e92f58f58a73d99ee4e1304e64eb2";
    lanzaboote.url = "github:nix-community/lanzaboote/001e560fffc8f0235e9db20ebeb4ccde0ade1caf";
    sops-nix.url = "github:Mic92/sops-nix/dcd241ba97088c22569d1573286e1b9daad340c0";
    sing-box-geosite = {
      url = "github:lyc8503/sing-box-rules/rule-set-geosite";
      flake = false;
    };
    sing-box-geoip = {
      url = "github:lyc8503/sing-box-rules/rule-set-geoip";
      flake = false;
    };
    arkenfox-userjs = {
      url = "github:arkenfox/user.js";
      flake = false;
    };
    catppuccin-fcitx5 = {
      url = "github:catppuccin/fcitx5";
      flake = false;
    };
    reproducible-violentmonkey.url = "github:hellodword/reproducible-violentmonkey";
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    oranc = {
      url = "github:linyinfeng/oranc";
      flake = false;
    };
    apprise = {
      url = "github:caronc/apprise/v2.1.0";
      flake = false;
    };
    apprise-api = {
      url = "github:caronc/apprise-api/v2.0.2";
      flake = false;
    };
    vm-test-tools = {
      url = "github:hellodword/agents-misc";
      flake = false;
    };
  };
  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkLaptop =
        extraModules:
        nixpkgs.lib.nixosSystem {
          modules = [
            ./modules
            ./hosts/laptop2
          ]
          ++ extraModules;
          specialArgs = {
            inherit inputs;
            userName = "ubuntu";
          };
        };
      synthetic = mkLaptop [ ./tests/fixtures/host-credentials.nix ];
      laptop = mkLaptop [ ];
      vmTools = import (inputs.vm-test-tools + /nix/vm-test-mcp.nix) {
        inherit pkgs nixpkgs;
        lib = pkgs.lib;
      };
    in
    {
      nixosConfigurations.laptop2 = laptop;
      nixosModules.default = import ./modules;
      packages.${system} = import ./nix/packages.nix { inherit pkgs; };
      devShells.${system} = {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (p: [
              p.dnspython
              p.h2
              p.pyyaml
            ]))
            (import ./nix/route-regex.nix { inherit pkgs; })
            go
            openssl
            dnsdist
            dnsproxy
            dns-collector
            jq
            hujsonfmt
            sing-box
            restic
            sops
            age
            gnupg
            git
            openssh
            mkpasswd
            nixfmt
            shellcheck
            actionlint
            (callPackage (inputs.oranc + /package.nix) { })
            distribution
          ];
        };
        vm = pkgs.mkShell {
          packages = [
            (vmTools.package.overrideAttrs (_: {
              subPackages = [ "cmd/vm-test-submit" ];
              postBuild = "";
              postInstall = "";
            }))
          ];
        };
      };
      checks.${system} = import ./nix/checks.nix {
        inherit pkgs inputs;
        laptop = synthetic;
        production = laptop;
      };
    };
}
