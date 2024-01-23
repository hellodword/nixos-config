{ lib, stdenvNoCC, inputs, ... }:

stdenvNoCC.mkDerivation rec {
  pname = "loyalsoldier-v2ray-rules-dat";
  version = "v0.0.0-${inputs."${pname}".lastModifiedDate}-${inputs."${pname}".shortRev}";
  src = inputs."${pname}";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/v2ray
    mv * $out/share/v2ray

    runHook postInstall
  '';

  meta = with lib; {
    homepage = "https://github.com/Loyalsoldier/v2ray-rules-dat";
    description = "🦄 🎃 👻 V2Ray 路由规则文件加强版，可代替 V2Ray 官方 geoip.dat 和 geosite.dat，兼容 Shadowsocks-windows、Xray-core、Trojan-Go、leaf 和 hysteria。";
    license = licenses.gpl3;
    platforms = platforms.all;
  };
}
