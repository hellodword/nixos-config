{ config, lib, ... }:

let
  caBundle = toString config.security.pki.caBundle;
  distrustedRoots = [
    "AAA Certificate Services"
    "emSign ECC Root CA - G3"
    "emSign Root CA - C1"
    "emSign ECC Root CA - C3"
  ];
in
{
  # Temporary backport for nixpkgs 151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4.
  # Remove this module and its import once upstream contains all three fixes:
  # https://github.com/NixOS/nixpkgs/pull/576980
  nixpkgs.overlays = [
    (
      _final: prev:
      let
        cronetFixed = prev.cronet-go.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            rootStore=naiveproxy/src/net/data/ssl/chrome_root_store
            fingerprint=86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b

            grep -q '^# CN=emSign ECC Root CA - G3,' "$rootStore/root_store.textproto"
            grep -Fxq "# $fingerprint" "$rootStore/root_store.certs"

            sed -i '/^# CN=emSign ECC Root CA - G3,/,/^}/d' "$rootStore/root_store.textproto"
            sed -i "/^# $fingerprint$/,/^-----END CERTIFICATE-----$/d" "$rootStore/root_store.certs"

            if grep -Fq 'emSign ECC Root CA - G3' "$rootStore/root_store.textproto" ||
               grep -Fq "$fingerprint" "$rootStore/root_store.certs"; then
              echo "Failed to remove distrusted Cronet root" >&2
              exit 1
            fi
          '';
        });
      in
      {
        sing-box =
          assert lib.assertMsg (
            prev.sing-box.version == "1.14.1" && prev.cronet-go.version == "150.0.7871.63-3"
          ) "Review or remove the temporary laptop2 eMudhra mitigation after updating nixpkgs.";
          (prev.sing-box.override { cronet-go = cronetFixed; }).overrideAttrs (
            old:
            let
              oldCopy = "cp -r ${cronetFixed}/ .";
              postConfigure = lib.replaceStrings [ oldCopy ] [ "cp -r ${cronetFixed}/. ." ] (
                old.postConfigure or ""
              );
            in
            assert lib.assertMsg (
              postConfigure != (old.postConfigure or "")
            ) "Unexpected sing-box postConfigure; review or remove the temporary Cronet replacement.";
            {
              postPatch = (old.postPatch or "") + ''
                for ca in ${lib.escapeShellArgs distrustedRoots}; do
                  grep -Fxq "// $ca" common/certificate/mozilla.go
                  sed -i -E \
                    "/^\/\/ (CN=)?$ca(;|$)/,/^-----END CERTIFICATE-----$/d" \
                    common/certificate/{mozilla,chrome}.go

                  if grep -Fq "$ca" common/certificate/{mozilla,chrome}.go; then
                    echo "Failed to remove embedded root: $ca" >&2
                    exit 1
                  fi
                done
              '';
              inherit postConfigure;
            }
          );
      }
    )
  ];

  systemd.services = lib.genAttrs [ "sing-box" "mosdns" "mosdns-cn" "tailscaled" ] (_: {
    environment = {
      SSL_CERT_FILE = caBundle;
      SSL_CERT_DIR = builtins.dirOf caBundle;
    };
    restartTriggers = [ config.security.pki.caBundle ];
  });
}
