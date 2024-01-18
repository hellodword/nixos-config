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
    sops-nix.url = "github:Mic92/sops-nix/36b062a2c85a0efb37de1300c79c54602a094fab";

    lanzaboote = {
      url = "github:nix-community/lanzaboote/e9003f12e63588736dde12acf95a4d0361b215e5";

      # Optional but recommended to limit the size of your system closure.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko/f0b9f374bb42fdcd57baa7d4448ac5d4788226bd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/Baitinq/nixos-config/blob/1ab479c29c7dc2629664ffb80653616666019b9e/flake.nix#L32
    arkenfox-userjs = {
      url = "github:arkenfox/user.js";
      flake = false;
    };
    thunderbird-userjs = {
      url = "github:HorlogeSkynet/thunderbird-user.js/ac8a715b067749c9a7845d2fe862764f34bef20f";
      flake = false;
    };

    nixos-privates.url = "git+ssh://git@hellodword.github.com/hellodword/nixos-privates.git";

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions/69e5964e445ae35ae3c17f8c7dcf2a22dbcff94c?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    kitty-gruvbox-themes = {
      url = "github:wdomitrz/kitty-gruvbox-theme/b930abcc3a1cdcc763fb65988f07ee0270710f9c";
      flake = false;
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

    # use this fork for git repository
    flake-compat = {
      url = "github:inclyc/flake-compat/70e56389c58bbd300d11778913b255477ebbae22";
      flake = false;
    };

    catppuccin-sddm = {
      url = "github:catppuccin/sddm";
      flake = false;
    };

    localsend-discovery = {
      url = "github:hellodword/localsend-discovery";
      flake = false;
    };

    lxgw-fusion-kai = {
      url = "github:lxgw/FusionKai";
      flake = false;
    };

    rime-ice = {
      url = "github:iDvel/rime-ice/4c69722470e7ed6a27cb6f1f1633ceb03487a893";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, home-manager, lanzaboote, sops-nix, nixos-hardware, disko, ... }@ inputs:
    let
      inherit (self) outputs;
      forEachSystem = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      # forEachPkgs = f: forEachSystem (sys: f nixpkgs.legacyPackages.${sys});
      commonArgs = { persistPath = "/persist"; };
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

      # vbox
      nixosConfigurations."vbox" = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/vbox
        ];
        specialArgs = {
          commonArgs = commonArgs;
          inherit inputs outputs;
        } // commonArgs;
      };

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

    };
}
