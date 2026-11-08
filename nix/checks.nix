{
  pkgs,
  inputs,
  laptop,
  userName,
}:
let
  pythonCheck =
    name: paths: tools: command:
    let
      source = pkgs.lib.fileset.toSource {
        root = ../.;
        fileset =
          pkgs.lib.fileset.intersection (pkgs.lib.fileset.fileFilter (file: file.hasExt "py") ../.)
            (
              pkgs.lib.fileset.unions (
                [
                  ../tests/__init__.py
                  ../tests/support.py
                  ../tests/integration/__init__.py
                  ../tests/unit/__init__.py
                ]
                ++ paths
              )
            );
      };
    in
    pkgs.runCommand name { nativeBuildInputs = tools; } ''
      cp -r ${source}/. .
      ${command}
      touch $out
    '';
  collector = (pkgs.formats.json { }).generate "dns-collector.json" (
    import ../lib/dns-collector.nix { }
  );
  policy = pkgs.writeText "network-test-policy.json" (
    builtins.toJSON (import ../tests/fixtures/network-policy.nix { inherit (pkgs) lib; })
  );
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
    p.dnspython
    p.h2
  ]);
in
rec {
  backup =
    pythonCheck "backup-behavior"
      [ ../scripts/backup ../tests/unit/test_backup.py ../tests/integration/backup.py ]
      [ python pkgs.restic ]
      ''
        python3 -m unittest tests.unit.test_backup -v
        python3 -m tests.integration.backup -v
      '';
  identity =
    pythonCheck "identity-registration"
      [
        ../scripts/secrets
        ../tests/integration/secrets.py
        ../tests/fixtures/gpg_identity.py
        ../tests/fixtures/__init__.py
      ]
      [ python pkgs.sops pkgs.age pkgs.gnupg pkgs.git pkgs.openssh ]
      ''
        python3 -m tests.integration.secrets -v
      '';
  network =
    pythonCheck "network-protocol-tests"
      [
        ../scripts/network
        ../tests/unit/test_network.py
        ../tests/integration/dns.py
        ../tests/integration/network.py
        ../tests/fixtures/__init__.py
        ../tests/fixtures/dns_fixture.py
        ../tests/fixtures/network_fixture.py
      ]
      [
        python
        pkgs.hujsonfmt
        pkgs.sing-box
        (import ./route-regex.nix { inherit pkgs; })
        pkgs.dnsdist
        pkgs.dnsproxy
        pkgs.dns-collector
        pkgs.openssl
      ]
      ''
        python3 -m unittest tests.unit.test_network -v
        python3 -m tests.integration.dns --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} > $out
        python3 -m tests.integration.network --sing-box ${pkgs.sing-box}/bin/sing-box --template ${policy} --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} >> $out
      '';
  configuration = import ../tests/configuration.nix { inherit pkgs laptop userName; };
  desktop = import ../tests/desktop.nix {
    inherit pkgs userName;
    config = laptop.config;
  };
  vm-desktop = pkgs.testers.runNixOSTest (import ../tests/vm/desktop.nix { inherit inputs; });
  vm-applications = pkgs.testers.runNixOSTest (
    import ../tests/vm/applications.nix { inherit inputs; }
  );
  vm-backup = pkgs.testers.runNixOSTest (import ../tests/vm/backup.nix { inherit inputs; });
  vm-network = pkgs.testers.runNixOSTest (import ../tests/vm/network.nix { inherit inputs; });
  e2e = pkgs.linkFarm "nixos-vm-tests" (
    map
      (name: {
        inherit name;
        path = builtins.getAttr name {
          inherit
            vm-desktop
            vm-applications
            vm-backup
            vm-network
            ;
        };
      })
      [
        "vm-network"
        "vm-desktop"
        "vm-applications"
        "vm-backup"
      ]
  );
}
