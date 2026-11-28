{ inputs, system }:
let
  shell =
    scope:
    let
      laptop = scope == "laptop";
      pkgs = inputs.${if laptop then "nixpkgs" else "nixpkgs-remote"}.legacyPackages.${system};
      tools = import ./dev-tools.nix { inherit inputs pkgs system; };
      python = pkgs.python3.withPackages (p: [
        p.cryptography
        p.pyyaml
        p.dnspython
        p.h2
      ]);
    in
    pkgs.mkShell {
      shellHook = ''
        devtools_project="$(${pkgs.gitMinimal}/bin/git rev-parse --show-toplevel)" || exit 1
        devtools_cache="$devtools_project/tmp/.cache/nixos-config-tools"
        export XDG_CACHE_HOME="$devtools_cache/shell/cache"
        export TMPDIR="$devtools_cache/shell/tmp"
        export GOCACHE="$devtools_cache/go/build"
        export GOPATH="$devtools_cache/go"
        export PYTHONNOUSERSITE=1
        export EDITOR=vim
        mkdir -p -m 700 "$XDG_CACHE_HOME" "$TMPDIR" "$HOME/.cache/nix"
        # Reuse the laptop's persistent Nix cache across both shells and wrappers.
        if [[ ! -e "$XDG_CACHE_HOME/nix" ]]; then
          ln -s "$HOME/.cache/nix" "$XDG_CACHE_HOME/nix"
        fi
      '';
      packages =
        with pkgs;
        [
          python
          openssl
          jq
          sops
          age
          gnupg
          git
          openssh
          nix
          nixfmt
          nix-eval-jobs
          ruff
          shellcheck
          curl
          bubblewrap
          tools.sing-box
          tools.actionlint
          tools.oranc
          vim
        ]
        ++ lib.optionals laptop [
          (import ./route-regex.nix { inherit pkgs; })
          go
          hujsonfmt
          restic
          mkpasswd
          distribution
          tools.dnsdist
          tools.dnsproxy
          tools.dns-collector
        ]
        ++ lib.optionals (!laptop) [
          netcat-openbsd
          wireguard-tools
          openvpn
          (import ./wrangler.nix { inherit pkgs; })
          inputs.colmena.packages.${system}.default
        ];
    };
in
{
  laptop = shell "laptop";
  vps = shell "vps";
}
