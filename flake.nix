{
  description = "Ubuntu's NixOS Flake";

  inputs = {
    # https://nixos.org/manual/nixos/unstable/options.html
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # "github:NixOS/nixpkgs/release-22.11";
    # https://nix-community.github.io/home-manager/options.html
    home-manager = {
      url = "github:nix-community/home-manager"; # "github:nix-community/home-manager/release-22.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    impermanence.url = "github:nix-community/impermanence";
    sops-nix.url = "github:Mic92/sops-nix/83b68a0e8c94b72cdd0a6e547a14ca7eb1c03616";

    lanzaboote = {
      url = "github:nix-community/lanzaboote/ded8d23709f94aedb1407bee9e26581f258e9e3a";

      # Optional but recommended to limit the size of your system closure.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko/5a2dc95464080764b9ca1b82b5d6d981157522be";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/flake.nix#L32
    arkenfox-userjs = {
      url = "github:arkenfox/user.js";
      flake = false;
    };
    # thunderbird-userjs = {
    #   url = "github:HorlogeSkynet/thunderbird-user.js/d6b18302e46349d9924c8a76951bae6efca51501";
    #   flake = false;
    # };

    nixos-privates.url = "git+ssh://git@hellodword.github.com/hellodword/nixos-privates.git";

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions/d1f6bbea177a3542d9ad3ecead77089b65e09963?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    you-know-who = {
      url = "github:hellodword/you-know-who/assets";
      flake = false;
    };

    nix-index-database = {
      url = "github:Mic92/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-vscode-ext = {
      url = "github:hellodword/nix-vscode-ext/nixos-unstable";
    };

    catppuccin-sddm = {
      url = "github:catppuccin/sddm/95bfcba80a3b0cb5d9a6fad422a28f11a5064991";
      flake = false;
    };

    lxgw-fusion-kai = {
      url = "github:lxgw/FusionKai/0bd3ae7ffcd1f290b8db5047ef31b74573368407";
      flake = false;
    };

    rime-ice = {
      url = "github:iDvel/rime-ice/fc2a5eb7aafa73148b7bc4508e9995b492cecd5a";
      flake = false;
    };

    auditd-rules = {
      url = "github:Neo23x0/auditd";
      flake = false;
    };

    catppuccin-kitty = {
      url = "github:catppuccin/kitty/d7d61716a83cd135344cbb353af9d197c5d7cec1";
      flake = false;
    };

    catppuccin-alacritty = {
      url = "github:catppuccin/alacritty/94800165c13998b600a9da9d29c330de9f28618e";
      flake = false;
    };

    catppuccin-fcitx5 = {
      url = "github:catppuccin/fcitx5/ce244cfdf43a648d984719fdfd1d60aab09f5c97";
      flake = false;
    };

    microvm.url = "github:astro/microvm.nix";

    android-nixpkgs = {
      # url = "github:tadfisher/android-nixpkgs/stable";
      url = "github:tadfisher/android-nixpkgs/c500d23a40a7db979537655f914cbc1609b14bbd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, home-manager, lanzaboote, sops-nix, nixos-hardware, disko, microvm, ... }@ inputs:
    let
      inherit (self) outputs;
      forEachSystem = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
      commonArgs = { persistPath = "/persist"; userName = "ubuntu"; };

    in
    {
      nixosModules = import ./modules/nixos;
      homeManagerModules = import ./modules/home-manager;

      overlays = import ./overlays { inherit inputs outputs; };

      # Your custom packages
      # Accessible through 'nix build', 'nix shell', etc
      packages = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in import ./pkgs { inherit pkgs; }
      );

      # laptop2
      nixosConfigurations."laptop2" = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/laptop2
        ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

      # laptop3
      nixosConfigurations."laptop3" = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/laptop3
        ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };


      # r86s
      nixosConfigurations."r86s" = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/r86s
        ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

      # nix build .#nixosConfigurations.test-vm-minimal.config.system.build.vm
      # rm nixos.qcow2
      # QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22" ./result/bin/run-nixos-vm
      # NIX_DISK_IMAGE=test1.qcow2 QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22" nix run .#nixosConfigurations.test-vm-minimal.config.system.build.vm
      # ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no admin@localhost -p 2221
      nixosConfigurations."test-vm-minimal" = nixpkgs.lib.nixosSystem {
        modules = [
          {
            nixpkgs.hostPlatform = "x86_64-linux";
          }
          ./vms/minimal.nix
        ];
      };

      # nix build .#nixosConfigurations.test-vm-x.config.system.build.vm
      # rm nixos.qcow2
      # QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22,hostfwd=tcp:127.0.0.1:3389-:3389" ./result/bin/run-nixos-vm
      nixosConfigurations."test-vm-x" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./vms/x.nix
        ];
      };


      nixosConfigurations."test-tailscale" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./vms/tailscale.nix
        ];
      };

      nixosConfigurations."test-zerotier" = forEachSystem (system: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./vms/zerotier.nix
        ];
      });

      # nix run .#nixosConfigurations."microvm-minimal".<system>.config.microvm.declaredRunner
      nixosConfigurations."microvm-minimal" = forEachSystem (system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          microvm.nixosModules.microvm
          ./vms/microvm-minimal.nix
        ];
      });

    };
}
