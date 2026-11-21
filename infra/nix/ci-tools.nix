{
  pkgs,
  oranc,
  root,
}:
let
  inherit (pkgs) lib;
  python = pkgs.python3.withPackages (p: [ p.cryptography ]);
  source = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions (
      map lib.fileset.maybeMissing [
        (root + "/ci")
        (root + "/nix")
        (root + "/scripts")
      ]
    );
  };
  runtimeTools = [
    python
    pkgs.nix
    pkgs.git
    pkgs.gh
    pkgs.jq
    pkgs.skopeo
    pkgs.actionlint
    pkgs.shellcheck
    pkgs.nixfmt
    pkgs.nix-eval-jobs
    pkgs.distribution
    oranc
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.bash
  ];
  nixCi = pkgs.runCommand "nix-ci" { } ''
    mkdir -p "$out/bin" "$out/libexec"
    cp -r ${source} "$out/libexec/infra"
    cat > "$out/bin/nix-ci" <<EOF
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    export PATH="\''${PATH:+\$PATH:}${lib.makeBinPath runtimeTools}"
    export NIX_CI_INFRA_DIR="$out/libexec/infra"
    exec ${python}/bin/python3 "$out/libexec/infra/ci" "\$@"
    EOF
    chmod 0755 "$out/bin/nix-ci"
  '';
in
pkgs.buildEnv {
  name = "ci-tools";
  paths = [
    nixCi
    python
    pkgs.git
    pkgs.gh
    pkgs.jq
    pkgs.skopeo
    pkgs.actionlint
    pkgs.shellcheck
    pkgs.nixfmt
    pkgs.nix-eval-jobs
    pkgs.distribution
    oranc
  ];
}
