# https://github.com/ironman820/flake/blob/4067262ecee52d92a2e295076076c48e17f156e2/packages/sddm-catppuccin/default.nix
{ stdenvNoCC, qt5, catppuccin-sddm }:
# let
#   inherit (pkgs.stdenvNoCC) mkDerivation;
#   inherit (pkgs.qt5)
#     qtbase qtgraphicaleffects qtquickcontrols2 qtsvg wrapQtAppsHook;
# in
stdenvNoCC.mkDerivation {
  dontBuild = true;
  pname = "catppuccin-sddm";
  version = "1.0";

  nativeBuildInputs = [ qt5.wrapQtAppsHook ];

  propagatedUserEnvPkgs = [ qt5.qtbase qt5.qtgraphicaleffects qt5.qtquickcontrols2 qt5.qtsvg ];

  src = catppuccin-sddm;

  installPhase = ''
    mkdir -p $out/share/sddm/themes
    cp -aR $src/src/* $out/share/sddm/themes/
  '';

  # postFixup = ''
  #   sed -i 's|Backgrounds/win11.png|Backgrounds/shacks.png|' $out/share/sddm/themes/tokyo-night-sddm/theme.conf
  # '';
}
