{ lib, ... }:

{
  # @cc [owner:ghuntley,label:security] fleet-distrust-emudhra-roots
  # Every NixOS system Overalls builds (hosts, the kexec installer and NixOS
  # guests) MUST distrust the roots chaining to the eight eMudhra intermediates
  # whose keys leaked in October 2026. Upstream nixos-26.05 appends the same
  # names in security/ca.nix (nixpkgs 7816d39); delete this module once the
  # pinned nixpkgs contains that change.
  security.pki.caCertificateBlacklist = lib.mkAfter [
    # Compromised eMudhra intermediates also have Sectigo cross-signs.
    # https://github.com/NixOS/nixpkgs/issues/576485
    "Comodo AAA Services root"
    "emSign ECC Root CA - G3"
    # Retired roots removed alongside the compromise mitigation in NSS 3.131.1.
    # https://bugzilla.mozilla.org/show_bug.cgi?id=2083709
    "emSign Root CA - C1"
    "emSign ECC Root CA - C3"
  ];
}
