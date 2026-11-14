{ inputs, system }:
let
  shell =
    scope:
    let
      laptop = scope == "laptop";
      pkgs = inputs.${if laptop then "nixpkgs" else "nixpkgs-remote"}.legacyPackages.${system};
      sandbox = import ./tool-sandbox.nix { inherit pkgs; };
      networkTool =
        name: package:
        sandbox {
          inherit name package;
          network = true;
          writable = [ "tmp/devtools/network" ];
        };
      python = pkgs.python3.withPackages (p: [
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
        export npm_config_cache="$devtools_cache/npm"
        mkdir -p -m 700 "$XDG_CACHE_HOME" "$TMPDIR" "$HOME/.cache/nix"
        case "$(${pkgs.coreutils}/bin/stat -f -c %T "$TMPDIR")" in
          tmpfs|ramfs)
            printf 'Use a persistent checkout for development tools: %s\n' "$devtools_project" >&2
            exit 1
            ;;
        esac
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
          nixfmt
          shellcheck
          curl
          bubblewrap
          (networkTool "sing-box" sing-box)
          (sandbox {
            package = actionlint;
            runtime = [ shellcheck ];
          })
          (sandbox {
            name = "oranc";
            package = inputs.oranc.packages.${system}.oranc;
            network = true;
            nix = true;
            database = true;
            runtime = [ nix ];
            writable = [ "tmp/devtools/cache" ];
            passEnvironment = [
              "ORANC_USERNAME"
              "ORANC_PASSWORD"
              "ORANC_SIGNING_KEY"
              "NIX_CONFIG"
            ];
          })
        ]
        ++ lib.optionals laptop [
          (import ./route-regex.nix { inherit pkgs; })
          go
          hujsonfmt
          restic
          mkpasswd
          distribution
          inputs.agents-misc.packages.${system}.vm-test-submit
          (networkTool "dnsdist" dnsdist)
          (networkTool "dnsproxy" dnsproxy)
          (networkTool "go-dnscollector" dns-collector)
        ]
        ++ lib.optionals (!laptop) [
          nodejs
          wireguard-tools
          openvpn
          (import ./wrangler.nix { inherit pkgs; })
          (sandbox {
            name = "colmena";
            package = inputs.colmena.packages.${system}.default;
            runtime = [
              nix
              git
              openssh
              netcat-openbsd
            ];
            network = true;
            nix = true;
            ssh = true;
            readable = [
              "tmp/vps/metadata.json"
              "tmp/vps/nodes"
            ];
            passEnvironment = [ "NIX_CONFIG" ];
          })
        ];
    };
in
{
  laptop = shell "laptop";
  vps = shell "vps";
}
