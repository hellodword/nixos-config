{ pkgs }:
pkgs.sway.override {
  sway-unwrapped = pkgs.sway-unwrapped.overrideAttrs (old: {
    patches =
      (old.patches or [ ])
      ++ pkgs.lib.optional (pkgs.lib.versionOlder old.version "1.13") ./patches/sway-input-method-lifecycle.patch
      ++ [ ./patches/sway-popup-listener.patch ];
  });
}
