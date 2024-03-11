# Shell for bootstrapping flake-enabled nix and other tooling
{ pkgs ? # If pkgs is not defined, instantiate nixpkgs from locked commit
  let
    lock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
    nixpkgs = fetchTarball {
      url = "https://github.com/nixos/nixpkgs/archive/${lock.rev}.tar.gz";
      sha256 = lock.narHash;
    };
  in
  import nixpkgs { overlays = [ ]; }
, ...
}:

{
  default = pkgs.mkShell {
    NIX_CONFIG = "extra-experimental-features = nix-command flakes repl-flake";
    nativeBuildInputs = with pkgs; [
      nix
      home-manager
      git

      sops
      ssh-to-age
      gnupg
      age

      nixpkgs-fmt
      rnix-lsp
      gnumake

      nil
      nixfmt

      nix-prefetch
      nix-prefetch-bzr
      nix-prefetch-cvs
      nix-prefetch-docker
      nix-prefetch-git
      nix-prefetch-github
      nix-prefetch-hg
      nix-prefetch-scripts
      nix-prefetch-svn
    ];

    hardeningDisable = [ "all" ];
  };
}
