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
    sops-nix = {
      url = "github:Mic92/sops-nix/b6cb5de2ce57acb10ecdaaf9bbd62a5ff24fa02e";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/e7bd94e0b5ff3c1e686f2101004ebf4fcea9d871";

      # Optional but recommended to limit the size of your system closure.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      # DO NOT UPGRADE https://github.com/nix-community/disko/issues/586
      url = "github:nix-community/disko/5a2dc95464080764b9ca1b82b5d6d981157522be";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/flake.nix#L32
    arkenfox-userjs = {
      url = "github:arkenfox/user.js/ff5c959cb9b5a65ede9aab82b00cbb283b160e14";
      flake = false;
    };
    # thunderbird-userjs = {
    #   url = "github:HorlogeSkynet/thunderbird-user.js/d6b18302e46349d9924c8a76951bae6efca51501";
    #   flake = false;
    # };

    nixos-privates.url = "git+ssh://git@hellodword.github.com/hellodword/nixos-privates.git";

    firefox-addons = {
      # https://gitlab.com/rycee/nur-expressions/-/compare/a9250ac868999a4ddd4c709859a9eb1d2075c8fd...master
      url = "gitlab:rycee/nur-expressions/a9250ac868999a4ddd4c709859a9eb1d2075c8fd?dir=pkgs/firefox-addons";
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

    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
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

    android-nixpkgs = {
      # url = "github:tadfisher/android-nixpkgs/stable";
      url = "github:tadfisher/android-nixpkgs/c500d23a40a7db979537655f914cbc1609b14bbd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    anytype-flake = {
      url = "github:squalus/anytype-flake/5e07cfaaed6cf477d43a5fd5f2906a2cd4644a74";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firejail-src = {
      url = "github:netblue30/firejail/b89ec818926b4bcd3a58bb4e2a67b68a8090ba1c";
      flake = false;
    };

    reproducible-violentmonkey = {
      url = "github:hellodword/reproducible-violentmonkey";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      inherit (self) outputs;
      forEachSystem = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
      commonArgs = {
        persistPath = "/persist";
        userName = "ubuntu";
      };

    in
    {
      nixosModules = import ./modules/nixos;
      homeManagerModules = import ./modules/home-manager;

      overlays = import ./overlays { inherit inputs outputs; };

      # Your custom packages
      # Accessible through 'nix build', 'nix shell', etc
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./pkgs { inherit pkgs; }
      );

      # laptop2
      nixosConfigurations."laptop2" = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/laptop2 ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

      # laptop3
      nixosConfigurations."laptop3" = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/laptop3 ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

      # r86s
      nixosConfigurations."r86s" = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/r86s ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

      # nix build .#nixosConfigurations.vm-minimal.config.system.build.vm
      # rm nixos.qcow2
      # QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22" ./result/bin/run-nixos-vm
      # NIX_DISK_IMAGE=test1.qcow2 QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22" nix run .#nixosConfigurations.vm-minimal.config.system.build.vm
      # ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no admin@localhost -p 2221
      nixosConfigurations."vm-minimal" = nixpkgs.lib.nixosSystem { modules = [ ./hosts/vm-minimal ]; };

      # QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:2221-:22,hostfwd=tcp:127.0.0.1:3389-:3389" ./result/bin/run-nixos-vm
      nixosConfigurations."vm-x11" = nixpkgs.lib.nixosSystem { modules = [ ./hosts/vm-x11 ]; };

      nixosConfigurations."vm-wayland" = nixpkgs.lib.nixosSystem { modules = [ ./hosts/vm-wayland ]; };

      nixosConfigurations."vm-android-studio" = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/vm-android-studio ];
      };

    };
}
