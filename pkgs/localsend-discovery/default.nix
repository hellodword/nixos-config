{ lib, buildGoModule, makeWrapper, fetchFromGitHub, ... }:

buildGoModule rec {
  pname = "localsend-discovery";
  # go install github.com/hellodword/localsend-discovery@latest
  version = "v0.0.0-20230731035253-7dd8e549840a";

  src = fetchFromGitHub {
    owner = "hellodword";
    repo = pname;
    rev = "7dd8e549840a96159fe9de88a3bd79c9b20703ad";
    # nix-prefetch-git https://github.com/hellodword/localsend-discovery
    hash = "sha256-u0Hl7v5JmAOEXgyDqtiLdeo2SGbozwe2nzctruzro4M=";
  };

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
