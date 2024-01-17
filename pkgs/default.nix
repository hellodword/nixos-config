{ pkgs ? import <nixpkgs> { }, inputs ? { }, ... }:

rec {
  rime-ice = pkgs.callPackage ./rime-ice { };
  localsend-discovery = pkgs.callPackage ./localsend-discovery { };
  eww-tray = pkgs.callPackage ./eww-tray { };

  # fonts
  kaixinsong-fonts = pkgs.callPackage ./kaixinsong-fonts { };
  hanyi-wenhei = pkgs.callPackage ./hanyi-wenhei { };
  plangothic-fonts = pkgs.callPackage ./plangothic-fonts { };
  jigmo = pkgs.callPackage ./jigmo { };
  noto-fonts-cjk-novf = pkgs.callPackage ./noto-fonts-cjk-novf { };
  fira-code-novf = pkgs.callPackage ./fira-code-novf { };
  harmonyos-sans = pkgs.callPackage ./harmonyos-sans { };
  lxgw-fusion-kai = pkgs.callPackage ./lxgw-fusion-kai { };

  # catppuccin
  catppuccin-sddm = pkgs.callPackage ./catppuccin-sddm { catppuccin-sddm = inputs.catppuccin-sddm; };
}
