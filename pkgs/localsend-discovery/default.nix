{ lib, buildGoModule, makeWrapper, fetchFromGitHub, ... }:

buildGoModule rec {
  pname = "localsend-discovery";
  # go install -v github.com/hellodword/localsend-discovery@master
  version = "v0.0.0-20230731060059-9ccd548aae05";

  src = fetchFromGitHub {
    owner = "hellodword";
    repo = pname;
    rev = "9ccd548aae059f0f9d3e6f836c83cc3b700a8b3a";
    # nix-prefetch-git https://github.com/hellodword/localsend-discovery
    hash = "sha256-pPwE0HpUKmkFdYSUync+DwSktf5MBQe8aNPhKQXijD4=";
  };

  vendorHash = null;

  ldflags = [ "-s" "-w" ];

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
