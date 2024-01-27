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
    sops-nix.url = "github:Mic92/sops-nix/4606d9b1595e42ffd9b75b9e69667708c70b1d68";

    lanzaboote = {
      url = "github:nix-community/lanzaboote/3c3f6d1b0f13a0e30d192838e233107182dec032";

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
    thunderbird-userjs = {
      url = "github:HorlogeSkynet/thunderbird-user.js/d6b18302e46349d9924c8a76951bae6efca51501";
      flake = false;
    };

    nixos-privates.url = "git+ssh://git@hellodword.github.com/hellodword/nixos-privates.git";

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions/24985136f4a5f98254e88c26d428114d206c2565?dir=pkgs/firefox-addons";
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

    # use this fork for git repository
    flake-compat = {
      url = "github:inclyc/flake-compat/70e56389c58bbd300d11778913b255477ebbae22";
      flake = false;
    };

    catppuccin-sddm = {
      url = "github:catppuccin/sddm/95bfcba80a3b0cb5d9a6fad422a28f11a5064991";
      flake = false;
    };

    lxgw-fusion-kai = {
      url = "github:lxgw/FusionKai";
      flake = false;
    };

    rime-ice = {
      url = "github:iDvel/rime-ice/2a2f956cc66eaf49c3068ecbd8102fdab3087e9e";
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

    catppuccin-fcitx5 = {
      url = "github:catppuccin/fcitx5/ce244cfdf43a648d984719fdfd1d60aab09f5c97";
      flake = false;
    };

    loyalsoldier-v2ray-rules-dat = {
      url = "github:Loyalsoldier/v2ray-rules-dat/release";
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
