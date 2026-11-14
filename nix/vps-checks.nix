{ inputs }:
let
  pkgs = inputs.nixpkgs-remote.legacyPackages.x86_64-linux;
  client = inputs.nixpkgs.legacyPackages.x86_64-linux.sing-box;
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
    p.dnspython
    p.h2
  ]);
in
{
  vps =
    pkgs.runCommand "vps-protocols"
      {
        nativeBuildInputs = [
          python
          pkgs.openssl
          pkgs.nodejs
          pkgs.wrangler
        ];
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        cp -r ${
          pkgs.lib.fileset.toSource {
            root = ../.;
            fileset = pkgs.lib.fileset.unions [
              ../scripts/vps
              ../scripts/network
              ../data/network
              ../workers
              ../data/secrets/vps.example.yaml
              ../tests/__init__.py
              ../tests/support.py
              ../tests/integration/__init__.py
              ../tests/integration/vps.py
              ../tests/integration/vps-workers.mjs
              ../tests/integration/network.py
              ../tests/integration/dns.py
              ../tests/fixtures
            ];
          }
        }/. .
        python3 -m tests.integration.vps \
          --server-sing-box ${pkgs.sing-box}/bin/sing-box \
          --client-sing-box ${client}/bin/sing-box -v
        touch $out
      '';
  vm-vps = pkgs.testers.runNixOSTest (import ../tests/vm/vps.nix { inherit inputs; });
}
