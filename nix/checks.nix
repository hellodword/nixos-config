{
  pkgs,
  inputs,
  laptop,
  production,
}:
let
  testSource =
    paths:
    pkgs.lib.fileset.toSource {
      root = ../.;
      fileset =
        pkgs.lib.fileset.intersection (pkgs.lib.fileset.fileFilter (file: file.hasExt "py") ../.)
          (
            pkgs.lib.fileset.unions (
              [
                ../tests/__init__.py
                ../tests/support.py
                ../tests/integration/__init__.py
              ]
              ++ paths
            )
          );
    };
  unitSource = testSource [
    ../scripts/secrets
    ../scripts/backup
    ../scripts/network
    ../scripts/desktop/layout.py
    ../tests/unit
    ../tests/integration/secrets.py
    ../tests/fixtures/gpg_identity.py
    ../tests/fixtures/__init__.py
    ../tests/integration/backup.py
  ];
  networkSource = testSource [
    ../scripts/network
    ../tests/integration/dns.py
    ../tests/integration/network.py
    ../tests/fixtures/__init__.py
    ../tests/fixtures/dns_fixture.py
    ../tests/fixtures/network_fixture.py
  ];
  collector = (pkgs.formats.json { }).generate "dns-collector.json" (
    import ../lib/dns-collector.nix { }
  );
  policy = pkgs.writeText "network-test-policy.json" (
    builtins.toJSON (import ../tests/fixtures/network-policy.nix { inherit (pkgs) lib; })
  );
in
rec {
  unit =
    pkgs.runCommand "configuration-behavior-tests"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (p: [ p.pyyaml ]))
          pkgs.sops
          pkgs.age
          pkgs.gnupg
          pkgs.git
          pkgs.openssh
          (import ./route-regex.nix { inherit pkgs; })
          pkgs.hujsonfmt
          pkgs.restic
        ];
      }
      ''
        cp -r ${unitSource}/. .
        python3 -m unittest discover -s tests/unit -t . -v
        python3 -m tests.integration.backup -v
        python3 -m tests.integration.secrets -v
        touch $out
      '';
  network =
    pkgs.runCommand "network-protocol-tests"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (p: [
            p.dnspython
            p.h2
          ]))
          pkgs.hujsonfmt
          pkgs.sing-box
          (import ./route-regex.nix { inherit pkgs; })
          pkgs.dnsdist
          pkgs.dnsproxy
          pkgs.dns-collector
          pkgs.openssl
        ];
      }
      ''
        cp -r ${networkSource}/. .
        python3 -m tests.integration.dns --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} > $out
        python3 -m tests.integration.network --sing-box ${pkgs.sing-box}/bin/sing-box --template ${policy} --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} >> $out
      '';
  configuration = import ../tests/configuration.nix { inherit pkgs laptop; };
  desktop = import ../tests/desktop.nix {
    inherit pkgs;
    config = laptop.config;
  };
  vm-desktop = pkgs.testers.runNixOSTest (import ../tests/vm/desktop.nix { inherit inputs; });
  vm-applications = pkgs.testers.runNixOSTest (
    import ../tests/vm/applications.nix { inherit inputs; }
  );
  vm-backup = pkgs.testers.runNixOSTest (import ../tests/vm/backup.nix { inherit inputs; });
  vm-network = pkgs.testers.runNixOSTest (import ../tests/vm/network.nix { inherit inputs; });
  e2e = pkgs.linkFarm "configuration-e2e" (
    [
      {
        name = "laptop2-system";
        path = production.config.system.build.toplevel;
      }
      {
        name = "laptop2-home";
        path = production.config.home-manager.users.ubuntu.home.activationPackage;
      }
    ]
    ++ (map
      (name: {
        inherit name;
        path = builtins.getAttr name {
          inherit
            unit
            network
            configuration
            desktop
            vm-desktop
            vm-applications
            vm-backup
            vm-network
            ;
        };
      })
      [
        "unit"
        "network"
        "configuration"
        "desktop"
        "vm-desktop"
        "vm-applications"
        "vm-backup"
        "vm-network"
      ]
    )
  );
}
