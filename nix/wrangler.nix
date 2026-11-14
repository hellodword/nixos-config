{ pkgs }:
let
  runtime = [
    pkgs.wrangler
    pkgs.nodejs
    pkgs.bash
    pkgs.coreutils
    pkgs.cacert
  ];
  closure = pkgs.closureInfo { rootPaths = runtime; };
  nsswitch = pkgs.writeText "wrangler-nsswitch.conf" ''
    passwd: files
    group: files
    hosts: files dns
  '';
in
pkgs.writeShellApplication {
  name = "wrangler";
  runtimeInputs = [
    pkgs.bubblewrap
    pkgs.coreutils
  ];
  text =
    builtins.replaceStrings
      [ "@closure@" "@runtimePath@" "@shell@" "@caBundle@" "@nsswitch@" "@wrangler@" ]
      [
        "${closure}/store-paths"
        (pkgs.lib.makeBinPath runtime)
        "${pkgs.bash}/bin/bash"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "${nsswitch}"
        "${pkgs.wrangler}/bin/wrangler"
      ]
      (builtins.readFile ../scripts/workers/wrangler.sh);
}
