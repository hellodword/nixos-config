{ pkgs }:
pkgs.mullvad.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/mullvad-routing-priority.patch ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    pkgs.rustfmt
    pkgs.clippy
  ];
  # Fail on patch formatting/lints before compiling all daemon binaries.
  # The package's normal test phase remains unchanged.
  preBuild = (old.preBuild or "") + ''
    cargo fmt --check --package talpid-routing
    cargo clippy --offline --locked --package talpid-routing --lib --no-deps -- -D warnings
  '';
})
