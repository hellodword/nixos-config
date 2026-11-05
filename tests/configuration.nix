{ pkgs, laptop }:
let
  inherit (pkgs) lib;
  defaults = {
    dns = true;
    mullvad = true;
    proxy = true;
    backup = true;
    cache = false;
    displayManager = true;
    browser = true;
    cli = true;
    tailscale = true;
    storage = {
      root = "/persist";
      backupSource = "/persist";
      ageKey = "/persist/var/lib/sops-nix/keys.txt";
      device = "/dev/mapper/crypt0";
    };
    sessions = [
      "i3"
      "plasma"
      "sway"
    ];
  };
  disabled = path: lib.setAttrByPath (lib.splitString "." path) (lib.mkForce false);
  cases = {
    full = { };
    cache = {
      module.site.cache = {
        enable = true;
        repository = "synthetic/cache-test";
        publicKey = "fixture:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
      expected.cache = true;
    };
    storage-root = {
      module.site.storage.persistRoot = lib.mkForce "/state";
      expected.storage = {
        root = "/state";
        backupSource = "/state";
        ageKey = "/state/var/lib/sops-nix/keys.txt";
        device = "/dev/mapper/crypt0";
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
    dns-only = {
      module.site.network = {
        singBox.enable = lib.mkForce false;
        lockdown.enable = lib.mkForce false;
      };
      expected = {
        mullvad = false;
        proxy = false;
      };
    };
    sing-box-only = {
      module.site.network = {
        dns.enable = lib.mkForce false;
        lockdown.enable = lib.mkForce false;
      };
      expected = {
        dns = false;
        mullvad = false;
      };
    };
    dns-and-sing-box = {
      module = disabled "site.network.lockdown.enable";
      expected.mullvad = false;
    };
    tailscale = {
      module = disabled "services.tailscale.enable";
      expected.tailscale = false;
    };
    backup = {
      module = disabled "site.backup.enable";
      expected.backup = false;
    };
    desktop = {
      module = disabled "site.desktop.enable";
      expected = {
        displayManager = false;
        sessions = [ ];
      };
    };
    apps = {
      module = disabled "site.apps.enable";
      expected.browser = false;
    };
    cli = {
      module = disabled "site.cli.enable";
      expected.cli = false;
    };
  }
  // lib.genAttrs [ "i3" "plasma" "sway" ] (session: {
    module.site.desktop = lib.genAttrs [ "i3" "plasma" "sway" ] (name: {
      enable = lib.mkForce (name == session);
    });
    expected.sessions = [ session ];
  });
  persistentState =
    config:
    let
      state = config.environment.persistence.${config.site.storage.persistRoot};
      directories = map (entry: {
        inherit (entry)
          directory
          user
          group
          mode
          ;
      });
      files = map (entry: {
        inherit (entry) file method;
        parent = { inherit (entry.parentDirectory) user group mode; };
      });
    in
    {
      directories = directories state.directories;
      files = files state.files;
      users = lib.mapAttrs (_: user: {
        directories = directories user.directories;
        files = files user.files;
      }) state.users;
    };
  evaluate =
    name: spec:
    let
      config = (laptop.extendModules { modules = [ (spec.module or { }) ]; }).config;
      actual = {
        dns = config.systemd.services ? site-dns;
        tailscale = config.services.tailscale.enable;
        storage = {
          root = config.site.storage.persistRoot;
          backupSource = config.site.backup.source;
          ageKey = config.sops.age.keyFile;
          device = config.fileSystems.${config.site.storage.persistRoot}.device;
        };
        mullvad = config.services.mullvad-vpn.enable;
        proxy = (config.systemd.services.sing-box.serviceConfig or { }) ? ExecStart;
        backup = config.systemd.services ? site-backup-b2-backup;
        cache = config.systemd.services ? oranc;
        displayManager = config.services.displayManager.sddm.enable;
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
      persistentState config == persistentState laptop.config
    ) "${name}: disabling a capability changed the laptop state inventory";
    builtins.deepSeq config.system.build.toplevel.drvPath { inherit name actual; };
in
pkgs.runCommand "configuration-scenarios.json"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.bash
    ];
    scenarios = pkgs.writeText "scenarios.json" (builtins.toJSON (lib.mapAttrsToList evaluate cases));
    credentials = laptop.config.system.build.sops-nix-manifest;
    loginCredentials = laptop.config.system.build.sops-nix-users-manifest;
  }
  ''
    export HOME="$TMPDIR/home" GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME"
    git init --bare upstream
    git init work
    cd work
    git config user.name Fixture
    git config user.email fixture@example.invalid
    git config alias.backup ${lib.escapeShellArg laptop.config.home-manager.users.ubuntu.programs.git.settings.alias.backup}
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
    cp "$scenarios" "$out"
  ''
