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
          pkgs.lib.fileset.intersection
            (pkgs.lib.fileset.fileFilter (file: file.hasExt "py" || file.hasExt "toml") ../.)
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
  lockdownContract = (pkgs.formats.json { }).generate "lockdown-contract.json" (
    import ../lib/lockdown.nix
  );
  policy = pkgs.writeText "network-test-policy.json" (
    builtins.toJSON (import ../tests/fixtures/network-policy.nix { inherit (pkgs) lib; })
  );
  purposePolicy =
    let
      client = laptop.extendModules {
        modules = [ { services.tailscale.enable = pkgs.lib.mkForce false; } ];
      };
    in
    pkgs.writeText "client-purpose-policy.json" (
      builtins.toJSON {
        inherit (client.config.site.network) purposeGroups routeFragments connectionFragments;
      }
    );
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
    p.dnspython
    p.h2
  ]);
in
rec {
  lint = import ./lint.nix { inherit pkgs; };
  inherit (import ./vps-checks.nix { inherit inputs; }) vps vm-vps;
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
        ../data/network/purposes.toml
        ../data/network/dns-upstreams.toml
        ../tests/unit/test_network.py
        ../tests/integration/dns.py
        ../tests/integration/network.py
        ../tests/fixtures/__init__.py
        ../tests/fixtures/dns_fixture.py
        ../tests/fixtures/dns_stack.py
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
        pkgs.mullvad
        pkgs.openssl
      ]
      ''
        python3 - ${lockdownContract} ${pkgs.mullvad}/bin/mullvad <<'PY'
        import json
        from pathlib import Path
        import subprocess
        import sys

        sys.path.insert(0, "scripts/network")
        import mullvad_contract

        expected = json.loads(Path(sys.argv[1]).read_text())
        assert expected == mullvad_contract.CONTRACT, (expected, mullvad_contract.CONTRACT)
        mullvad = sys.argv[2]
        for subcommand, tokens in (
            (["lockdown-mode", "set", "--help"], ("on", "off")),
            (["lan", "set", "--help"], ("allow", "block")),
            (["tunnel", "set", "--help"], ("mtu", "ipv6", "quantum-resistant")),
            (["relay", "set", "custom", "--help"], ("--v4-gateway", "--v6-gateway")),
            (["dns", "set", "default", "--help"], ()),
            (["auto-connect", "set", "--help"], ("on", "off")),
            (["connect", "--help"], ()),
            (["disconnect", "--help"], ()),
            (["status", "--help"], ()),
        ):
            help_text = subprocess.check_output([mullvad, *subcommand], text=True)
            for token in tokens:
                assert token in help_text, (subcommand, token)
        PY
        python3 -m unittest tests.unit.test_network -v
        python3 -m tests.integration.dns --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} > $out
        python3 -m tests.integration.network --sing-box ${pkgs.sing-box}/bin/sing-box --template ${policy} --purpose-policy ${purposePolicy} --dnsdist ${pkgs.dnsdist}/bin/dnsdist --dnsproxy ${pkgs.dnsproxy}/bin/dnsproxy --dnscollector ${pkgs.dns-collector}/bin/go-dnscollector --collector-template ${collector} >> $out
      '';
  desktop = import ../tests/desktop.nix {
    inherit pkgs userName;
    config = laptop.config;
  };
  vm-desktop = inputs.infra.lib.testing.mkTest pkgs (
    import ../tests/vm/desktop.nix { inherit inputs; }
  );
  vm-applications = inputs.infra.lib.testing.mkTest pkgs (
    import ../tests/vm/applications.nix { inherit inputs; }
  );
  vm-backup = inputs.infra.lib.testing.mkTest pkgs (
    import ../tests/vm/backup.nix { inherit inputs; }
  );
  vm-network = inputs.infra.lib.testing.mkTest pkgs (
    import ../tests/vm/network.nix { inherit inputs; }
  );
  vm-files = inputs.infra.lib.testing.mkTest pkgs (import ../tests/vm/files.nix { inherit inputs; });
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
            vm-files
            vm-vps
            ;
        };
      })
      [
        "vm-network"
        "vm-desktop"
        "vm-applications"
        "vm-backup"
        "vm-files"
        "vm-vps"
      ]
  );
}
// import ../tests/configuration.nix {
  inherit
    pkgs
    inputs
    laptop
    userName
    ;
}
