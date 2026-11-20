{
  description = "NixOS laptops and VPS, with explicit state and network policy";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-remote.url = "github:NixOS/nixpkgs/nixos-unstable";
    cloudflare-ips-v4 = {
      url = "file+https://www.cloudflare.com/ips-v4";
      flake = false;
    };
    cloudflare-ips-v6 = {
      url = "file+https://www.cloudflare.com/ips-v6";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Update installation and boot inputs independently with nix flake update <input>.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    reproducible-violentmonkey = {
      url = "github:hellodword/reproducible-violentmonkey";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    oranc.url = "github:linyinfeng/oranc";
    agents-misc = {
      url = "github:hellodword/agents-misc";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    colmena = {
      url = "github:nix-community/colmena";
      inputs.nixpkgs.follows = "nixpkgs-remote";
      inputs.stable.follows = "nixpkgs-remote";
    };
  };
  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkHost =
        {
          host,
          userName,
          system ? "x86_64-linux",
        }:
        nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = nixpkgs.lib.mkDefault system; }
            ./modules
            host
          ];
          specialArgs = { inherit inputs userName; };
        };
      synthetic = mkHost {
        host = ./tests/fixtures/laptop.nix;
        userName = "fixture";
      };
      vps = import ./nix/vps.nix { inherit inputs; };
    in
    {
      nixosConfigurations.laptop2 = mkHost {
        host = ./hosts/laptop2;
        userName = "ubuntu";
      };
      nixosModules.default = import ./modules;
      nixosModules.vps = import ./profiles/vps;
      colmenaHive = inputs.colmena.lib.makeHive vps.hive;
      vpsBootstrap = builtins.mapAttrs (_: node: node.config.system.build.image) vps.bootstrap;
      packages = forAllSystems (
        system:
        import ./nix/packages.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit inputs system;
        }
      );
      devShells = forAllSystems (system: import ./nix/dev-shells.nix { inherit inputs system; });
      checks.${system} = import ./nix/checks.nix {
        inherit pkgs inputs;
        laptop = synthetic;
        userName = "fixture";
      };
    };
}
