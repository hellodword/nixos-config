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
      url = "github:Mic92/sops-nix/d9d781523a1463965cd1e1333a306e70d9feff07";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/a65905a09e2c43ff63be8c0e86a93712361f871e";

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
      url = "github:arkenfox/user.js";
      flake = false;
    };
    # thunderbird-userjs = {
    #   url = "github:HorlogeSkynet/thunderbird-user.js/d6b18302e46349d9924c8a76951bae6efca51501";
    #   flake = false;
    # };

    nixos-privates.url = "git+ssh://git@hellodword.github.com/hellodword/nixos-privates.git";

    firefox-addons = {
      # https://gitlab.com/rycee/nur-expressions/-/compare/58848c079b92abf27e92786681fe771da505599f...master
      url = "gitlab:rycee/nur-expressions/58848c079b92abf27e92786681fe771da505599f?dir=pkgs/firefox-addons";
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
      url = "github:hellodword/anytype-flake/full";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    reproducible-violentmonkey = {
      url = "github:hellodword/reproducible-violentmonkey";
      flake = false;
    };

    sing-box-schema = {
      url = "git+https://gist.github.com/artiga033/fea992d95ad44dc8d024b229223b1002.git";
      flake = false;
    };

    firejail = {
      # https://github.com/netblue30/firejail/compare/30ba35f0b331dc488ac666b3644d9508027b20d7...master
      url = "github:netblue30/firejail/30ba35f0b331dc488ac666b3644d9508027b20d7";
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
