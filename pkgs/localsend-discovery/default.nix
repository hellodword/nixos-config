{ lib, buildGoModule, makeWrapper, inputs, ... }:

buildGoModule rec {
  pname = "localsend-discovery";
  version = "v0.0.0-${inputs."${pname}".lastModifiedDate}-${inputs."${pname}".shortRev}";
  src = inputs."${pname}";

  vendorSha256 = null;

  ldflags = [ "-s" "-w" "-buildid=" ];

  # subPackages = [ "main" ];

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm555 "$GOPATH"/bin/${pname} $out/bin/${pname}
    runHook postInstall
  '';

  meta = with lib; {
    description = "";
    homepage = "https://github.com/hellodword/localsend-discovery";
    license = with lib.licenses; [ mit ];
    platforms = platforms.all;
    maintainers = with maintainers; [ hellodword ];
  };
}
