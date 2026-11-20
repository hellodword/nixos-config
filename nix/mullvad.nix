{ pkgs }:
pkgs.mullvad.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./patches/mullvad-routing-priority.patch ];
})
