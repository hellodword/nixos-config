# https://github.com/iori2333/nix-config/blob/26431908e4e183611a4ca8fc090969be542d35d0/system/common/fonts/harmonyos-sans.nix
{
  lib,
  stdenvNoCC,
  fetchzip,
}:

stdenvNoCC.mkDerivation {
  pname = "harmonyos-sans";
  version = "1.0";

  src = fetchzip {
    url = "http://web.archive.org/web/20240117022207if_/https://developer.harmonyos.com/resource/image/design/res/download/general/HarmonyOS-Sans.zip";
    stripRoot = false;
    hash = "sha256-c10AIlce3WSqzKI9cq9LoobRJHgbqnzBo/d958Acz/A=";
  };

  installPhase = ''
    runHook preInstall

    install -Dm644 'HarmonyOS Sans'/HarmonyOS_Sans*/*.ttf -t $out/share/fonts/truetype

    runHook postInstall
  '';

  meta = with lib; {
    homepage = "https://developer.harmonyos.com/cn/design/resource";
    description = "HarmonyOS Sans font";
    longDescription = ''
      HarmonyOS Sans font
    '';
    platforms = platforms.all;
  };
}
