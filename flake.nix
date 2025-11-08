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
    # https://github.com/nix-community/impermanence/pull/264
    impermanence.url = "github:nix-community/impermanence/9128a383177ceb510e3d55535466d264e860c54b";
    sops-nix = {
      # https://github.com/Mic92/sops-nix/compare/ab8d56e85b8be14cff9d93735951e30c3e86a437...master
      url = "github:Mic92/sops-nix/ab8d56e85b8be14cff9d93735951e30c3e86a437";
      # inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      # https://github.com/nix-community/lanzaboote/compare/747b7912f49e2885090c83364d88cf853a020ac1...master
      url = "github:nix-community/lanzaboote/747b7912f49e2885090c83364d88cf853a020ac1";

      # # Optional but recommended to limit the size of your system closure.
      # inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      # DO NOT UPGRADE https://github.com/nix-community/disko/issues/586
      url = "github:nix-community/disko/5a2dc95464080764b9ca1b82b5d6d981157522be";
      # inputs.nixpkgs.follows = "nixpkgs";
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
      # DO NOT UPGRADE, only using the `buildFirefoxXpiAddon`
      # https://gitlab.com/rycee/nur-expressions/-/compare/435c7a1ce417f375269a04ec2a70fa53dcf6c36d...master
      url = "gitlab:rycee/nur-expressions/435c7a1ce417f375269a04ec2a70fa53dcf6c36d?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin-fcitx5 = {
      # https://github.com/catppuccin/fcitx5/compare/393845cf3ed0e0000bfe57fe1b9ad75748e2547f...main
      url = "github:catppuccin/fcitx5/393845cf3ed0e0000bfe57fe1b9ad75748e2547f";
      flake = false;
    };

    android-nixpkgs = {
      # url = "github:tadfisher/android-nixpkgs/stable";
      # https://github.com/tadfisher/android-nixpkgs/compare/c500d23a40a7db979537655f914cbc1609b14bbd...stable
      url = "github:tadfisher/android-nixpkgs/c500d23a40a7db979537655f914cbc1609b14bbd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    reproducible-violentmonkey = {
      url = "github:hellodword/reproducible-violentmonkey";
      flake = false;
    };

    # firejail = {
    #   # https://github.com/netblue30/firejail/compare/30ba35f0b331dc488ac666b3644d9508027b20d7...master
    #   url = "github:netblue30/firejail/30ba35f0b331dc488ac666b3644d9508027b20d7";
    #   flake = false;
    # };
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
        }
        // commonArgs;
      };

      # r86s
      nixosConfigurations."r86s" = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/r86s ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        }
        // commonArgs;
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
