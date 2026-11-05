{ pkgs }:
pkgs.sway.override {
  sway-unwrapped = pkgs.sway-unwrapped.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/sway-input-method-lifecycle.patch
      ./patches/sway-popup-listener.patch
    ];
  });
}
