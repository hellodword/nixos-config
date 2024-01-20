{ lib, buildGoModule, makeWrapper, fetchFromGitHub, ... }:

buildGoModule rec {
  pname = "mosdns";
  version = "5.3.1";
  src = fetchFromGitHub ({
    owner = "IrineSistiana";
    repo = "mosdns";
    rev = "v${version}";
    fetchSubmodules = false;
    sha256 = "sha256-QujkDx899GAImEtQE28ru7H0Zym5SYXJbJEfSBkJYjo=";
  });

  vendorHash = "sha256-0J5hXb1W8UruNG0KFaJBOQwHl2XiWg794A6Ktgv+ObM=";

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
    homepage = "https://github.com/IrineSistiana/mosdns";
    license = with lib.licenses; [ gpl3 ];
  };
}
