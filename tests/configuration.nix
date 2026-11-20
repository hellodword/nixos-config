{
  pkgs,
  inputs,
  laptop,
  userName,
}:
let
  inherit (pkgs) lib;
  defaults = {
    dns = true;
    mullvad = true;
    proxy = true;
    backup = true;
    cache = true;
    displayManager = true;
    browser = true;
    cli = true;
    tailscale = true;
    storage = {
      root = "/fixture-state";
      backupSource = "/fixture-state";
      ageKey = "/fixture-state/var/lib/sops-nix/keys.txt";
      device = "/dev/disk/by-label/fixture-state";
    };
    sessions = [
      "i3"
      "plasma"
      "sway"
    ];
  };
  minimalHeadless = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit inputs; };
    modules = [
      ../modules
      {
        system.stateVersion = "22.11";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
      }
    ];
  };
  cases = {
    full = { };
    laptop2 = {
      config = inputs.self.nixosConfigurations.laptop2.config;
      expected.storage = {
        root = "/persist";
        backupSource = "/persist";
        ageKey = "/persist/var/lib/sops-nix/keys.txt";
        device = "/dev/mapper/crypt0";
      };
    };
    headless = {
      module.site = {
        desktop.enable = lib.mkForce false;
        apps.enable = lib.mkForce false;
        productivity.enable = lib.mkForce false;
      };
      expected = {
        displayManager = false;
        browser = false;
        sessions = [ ];
      };
    };
    network-off = {
      module.site.network = {
        dns.enable = lib.mkForce false;
        singBox.enable = lib.mkForce false;
        lockdown.enable = lib.mkForce false;
      };
      expected = {
        dns = false;
        mullvad = false;
        proxy = false;
      };
    };
    dns-and-sing-box = {
      module.site.network.lockdown.enable = lib.mkForce false;
      expected.mullvad = false;
    };
    sway = {
      module.site.desktop = {
        i3.enable = lib.mkForce false;
        plasma.enable = lib.mkForce false;
        sway.enable = lib.mkForce true;
      };
      expected.sessions = [ "sway" ];
    };
  };
  evaluate =
    name: spec:
    let
      config = spec.config or (laptop.extendModules { modules = [ (spec.module or { }) ]; }).config;
      actual = {
        dns = config.systemd.services ? site-dns;
        tailscale = config.systemd.services ? tailscaled;
        storage = {
          root = config.site.storage.persistRoot;
          backupSource = config.site.backup.source;
          ageKey = config.sops.age.keyFile;
          device = config.fileSystems.${config.site.storage.persistRoot}.device;
        };
        mullvad = config.systemd.services ? mullvad-daemon;
        proxy = (config.systemd.services.sing-box.serviceConfig or { }) ? ExecStart;
        backup = config.systemd.services ? site-backup-b2-backup;
        cache = config.systemd.services ? oranc;
        displayManager = config.systemd.services ? display-manager;
        browser = config.programs.chromium.enable;
        cli = config.programs.nix-index.enable;
        sessions =
          lib.filter
            (
              session:
              {
                i3 = config.services.xserver.windowManager.i3.enable;
                plasma = config.services.desktopManager.plasma6.enable;
                sway = config.programs.sway.enable;
              }
              .${session}
            )
            [
              "i3"
              "plasma"
              "sway"
            ];
      };
      expected = defaults // (spec.expected or { });
      ownershipValid = lib.all (
        persistence:
        lib.all (
          entry:
          builtins.hasAttr entry.user config.users.users && builtins.hasAttr entry.group config.users.groups
        ) persistence.directories
      ) (builtins.attrValues config.environment.persistence);
    in
    assert lib.assertMsg (
      actual == expected
    ) "${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";
    assert lib.assertMsg ownershipValid "${name}: persistence refers to an unknown user or group";
    assert lib.assertMsg (
      name != "headless" || !minimalHeadless.config.site.home.enable
    ) "minimal headless system should leave site.home.enable disabled";
    builtins.deepSeq
      [
        config.system.build.toplevel.drvPath
        (if name == "headless" then minimalHeadless.config.system.build.toplevel.drvPath else "")
      ]
      (
        pkgs.runCommand "configuration-${name}.json" (
          {
            scenario = pkgs.writeText "scenario.json" (builtins.toJSON { inherit name actual; });
          }
          // lib.optionalAttrs (name == "full") {
            credentials = config.system.build.sops-nix-manifest;
            loginCredentials = config.system.build.sops-nix-users-manifest;
          }
        ) ''cp "$scenario" "$out"''
      );
in
lib.mapAttrs' (name: spec: lib.nameValuePair "configuration-${name}" (evaluate name spec)) cases
// {
  git-backup =
    pkgs.runCommand "git-backup"
      {
        nativeBuildInputs = [
          pkgs.git
          pkgs.bash
        ];
      }
      ''
        export HOME="$TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
        mkdir -p "$HOME"
        git init --bare upstream
        git init work
        cd work
        git config user.name Fixture
        git config user.email fixture@example.invalid
        git config alias.backup ${
          lib.escapeShellArg laptop.config.home-manager.users.${userName}.programs.git.settings.alias.backup
        }
        git remote add origin "$NIX_BUILD_TOP/upstream"
        git backup project
        for revision in first second; do
          echo "$revision" > document
          git add document
          git commit -m "$revision"
          git push origin HEAD:refs/heads/main
          test "$(git rev-parse HEAD)" = "$(git --git-dir="$HOME/backups/git/project" rev-parse refs/heads/main)"
          test "$(git rev-parse HEAD)" = "$(git --git-dir="$NIX_BUILD_TOP/upstream" rev-parse refs/heads/main)"
        done
        git remote remove origin
        git remote remove laptop-git-backup
        git backup -f local-only
        git push laptop-git-backup HEAD:refs/heads/main
        test "$(git rev-parse HEAD)" = "$(git --git-dir="$HOME/backups/git/local-only" rev-parse refs/heads/main)"
        touch "$out"
      '';
}
