# https://thekelleys.org.uk/gitweb/?p=dnsmasq.git;a=blob_plain;f=dnsmasq.conf.example;h=f1fb2d10d14b4105b6fb39b85a15098808b50395;hb=refs/tags/v2.90
# https://wiki.archlinux.org/title/Dnsmasq
{ pkgs, ... }:

let
  dnsmasq = pkgs.dnsmasq.overrideAttrs (oldAttrs: {
    version = "2.91rc1";
    src = pkgs.fetchurl {
      url = "https://www.thekelleys.org.uk/dnsmasq/release-candidates/dnsmasq-2.91rc1.tar.xz";
      hash = "sha256-x5s9Pqnd27siw6UW2tZsqdt3WY6enuACbj9iY0IuIAg=";
    };
    patches = [
      (builtins.fetchurl {
        url = "https://github.com/lixingcong/dnsmasq-regex/raw/refs/heads/master/patches/001-regex-server.patch";
        sha256 = "1zdvnapqspdh4n9i0hmbd6q5jy5np4pr428srkb5qxlk7rsjlcn0";
      })
    ];
    preBuild =
      builtins.replaceStrings [ "-DHAVE_NFTSET" ] [ "-DHAVE_NFTSET -DHAVE_REGEX" ]
        oldAttrs.preBuild;
    buildInputs = oldAttrs.buildInputs ++ [ pkgs.pcre ];
  });
in
{ }
