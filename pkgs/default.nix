{ pkgs ? import <nixpkgs> { }, ... }:

{
  rime-ice = pkgs.callPackage ./rime-ice { };
  librime-lua = pkgs.callPackage ./librime-lua { };
  localsend-discovery = pkgs.callPackage ./localsend-discovery { };

  # fonts
  jigmo = pkgs.callPackage ./jigmo { };
  # noto-fonts-cjk-novf = pkgs.callPackage ./noto-fonts-cjk-novf { };
  # fira-code-novf = pkgs.callPackage ./fira-code-novf { };
  harmonyos-sans = pkgs.callPackage ./harmonyos-sans { };
  lxgw-fusion-kai = pkgs.callPackage ./lxgw-fusion-kai { };

  mosdns = pkgs.callPackage ./mosdns { };

  bitwarden-desktop-issue = pkgs.callPackage ./bitwarden-desktop-issue { };
}
