{ inputs }:
{ pkgs, lib, ... }:
let
  notification = import ../fixtures/notifications.nix { inherit pkgs; };
  notificationPackages = import ../../nix/notifications.nix {
    inherit pkgs inputs;
    caBundle = notification.ca;
  };
in
{
  name = "restic-recovery";
  globalTimeout = 900;
  qemu.forceAccel = true;
  node.specialArgs = {
    inherit inputs;
    userName = "developer";
  };
  nodes.upstream = {
    imports = [ notification.server ];
    networking.firewall.enable = false;
    services.dnsmasq = {
      enable = true;
      settings = {
        address = [ "/#/192.168.1.2" ];
        no-resolv = true;
      };
    };
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = "192.168.1.2";
        prefixLength = 24;
      }
    ];
  };
  nodes.machine = {
    users.users.developer.isNormalUser = true;
    users.users.outsider.isNormalUser = true;
    site.containers = {
      enable = true;
    };
    security.pki.certificateFiles = [ notification.ca ];
    networking.nameservers = [ "192.168.1.2" ];
    networking.useDHCP = false;
    virtualisation.fileSystems."/persist" = {
      device = "/dev/vdb";
      fsType = "ext4";
      autoFormat = true;
      neededForBoot = true;
    };
    imports = [
      inputs.impermanence.nixosModules.impermanence
      ../../profiles/laptop/persistence.nix
      ../../modules/services/containers.nix
      ../../modules/services/notifications.nix
      notification.credentials
      ../../modules/services/backup.nix
    ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = [ 2048 ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.restic
      pkgs.python3
    ];
    site.backup = {
      enable = true;
      source = "/persist";
      roots = [
        {
          path = "data";
          required = true;
          excludeNames = [ "Cache" ];
        }
      ];
      targets = lib.genAttrs [ "first" "second" "third" ] (name: {
        repositoryFile = "/run/backup-test/${name}";
        passwordFile = "/run/backup-test/password";
        environmentFile = "/run/backup-test/environment";
        minute = 0;
      });
    };
    # Production targets are remote. Only these synthetic local repositories
    # need an extra writable mount in the otherwise identical service sandbox.
    systemd.services = lib.listToAttrs (
      lib.concatMap
        (
          target:
          map
            (
              operation:
              lib.nameValuePair "site-backup-${target}-${operation}" {
                serviceConfig.ReadWritePaths = [ "-/var/lib/repo-${target}" ];
                serviceConfig.TimeoutStartSec = lib.mkForce "90s";
              }
            )
            [
              "backup"
              "check"
              "restore-test"
              "maintenance"
            ]
        )
        [
          "first"
          "second"
          "third"
        ]
    );
  };
  testScript = builtins.readFile ./notifications.py + ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    notification_smoke(machine, upstream, "${notificationPackages.python}/bin/python3")
    machine.succeed("mkdir -p /persist/data/Cache /run/backup-test; echo important > /persist/data/document; echo disposable > /persist/data/Cache/blob")
    machine.succeed("printf 'synthetic-password' > /run/backup-test/password; touch /run/backup-test/environment; chmod 600 /run/backup-test/*")
    machine.succeed("systemd-tmpfiles --create")
    for target in ("first", "second", "third"):
        machine.succeed(f"echo /var/lib/repo-{target} > /run/backup-test/{target}")
        machine.succeed(f"RESTIC_PASSWORD_FILE=/run/backup-test/password restic -r /var/lib/repo-{target} init")
    # A destination failure neither marks success nor prevents another destination.
    machine.succeed("mv /var/lib/repo-second /var/lib/repo-second-offline")
    machine.fail("systemctl start site-backup-second-backup")
    machine.fail("test -e /var/lib/site-backup-second/backup-success.json")
    machine.succeed("mv /var/lib/repo-second-offline /var/lib/repo-second; systemctl reset-failed site-backup-second-backup")
    for target in ("first", "second", "third"):
        if target == "first":
            upstream.succeed("echo 3 > /run/notification-fixture/failures")
        machine.succeed(f"systemctl start site-backup-{target}-backup")
        if target == "first":
            delivery = json.loads(machine.succeed("cat /var/lib/site-backup-first/backup-notification.json"))
            assert not delivery["channels"][0]["delivered"], delivery
        state = json.loads(machine.succeed(f"cat /var/lib/site-backup-{target}/backup-success.json"))
        assert state["files"] == 2, state
        machine.succeed(f"systemctl start site-backup-{target}-check site-backup-{target}-restore-test")
        machine.succeed(f"test -s /var/lib/site-backup-{target}/restore-success.json")
        machine.succeed(f"systemctl start site-backup-{target}-maintenance")
        machine.succeed(f"test -s /var/lib/site-backup-{target}/maintenance-success.json")
        machine.succeed(f"RESTIC_PASSWORD_FILE=/run/backup-test/password restic -r /var/lib/repo-{target} restore latest --target /restore-{target} --verify")
        machine.succeed(f"cmp /persist/data/document /restore-{target}/data/document; test ! -e /restore-{target}/data/Cache")
    # A successful recent run skips without a new snapshot or write operation.
    before = machine.succeed("cat /var/lib/site-backup-first/backup-success.json")
    notified_before = machine.succeed("cat /var/lib/site-backup-first/backup-notification.json")
    machine.succeed("systemctl start site-backup-first-backup")
    assert machine.succeed("cat /var/lib/site-backup-first/backup-success.json") == before
    assert machine.succeed("cat /var/lib/site-backup-first/backup-notification.json") == notified_before
    # A mounted directory belongs to a separately selected filesystem.
    machine.succeed("mkdir -p /persist/data/mounted; mount -t tmpfs tmpfs /persist/data/mounted; echo external > /persist/data/mounted/document")
    machine.succeed("rm /var/lib/site-backup-third/backup-success.json")
    machine.fail("systemctl start site-backup-third-backup")
    machine.succeed("umount /persist/data/mounted; systemctl reset-failed site-backup-third-backup; systemctl start site-backup-third-backup")
    machine.succeed("RESTIC_PASSWORD_FILE=/run/backup-test/password restic -r /var/lib/repo-third restore latest --target /restore-retry --verify; cmp /persist/data/document /restore-retry/data/document")
    machine.succeed("systemctl stop site-backup-first-backup.timer; echo newer > /persist/data/document; rm /var/lib/site-backup-first/backup-success.json")
    machine.succeed("mkdir -p /var/lib/systemd/timers; touch -d '2 days ago' /var/lib/systemd/timers/stamp-site-backup-first-backup.timer")
    machine.succeed("mkdir -p /run/systemd/system/site-backup-first-backup.timer.d; printf '[Timer]\\nRandomizedDelaySec=0\\n' > /run/systemd/system/site-backup-first-backup.timer.d/test.conf; systemctl daemon-reload; systemctl start site-backup-first-backup.timer")
    machine.wait_until_succeeds("test -s /var/lib/site-backup-first/backup-success.json", timeout=90)
    machine.wait_until_succeeds("test $(systemctl show site-backup-first-backup.service -p SubState --value) = dead", timeout=120)
    machine.succeed("RESTIC_PASSWORD_FILE=/run/backup-test/password restic -r /var/lib/repo-first restore latest --target /restore-catchup --verify; cmp /persist/data/document /restore-catchup/data/document")
    for target in ("first", "second", "third"):
        machine.succeed(f"test $(stat -c %a /var/lib/site-backup-{target}) = 700")
        for operation in ("backup", "check", "restore-test"):
            delivery = json.loads(machine.succeed(f"cat /var/lib/site-backup-{target}/{operation}-notification.json"))
            assert delivery["channels"][0]["delivered"], delivery
    notifications = [json.loads(line) for line in upstream.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
    bodies = [str(event["body"]) for event in notifications]
    assert any("operation=backup; result=failure" in body for body in bodies), bodies
    assert all(any(f"operation={operation}; result=success" in body for body in bodies) for operation in ("backup", "check", "restore-test"))
    machine.succeed("systemctl start site-backup-status; backup-status > /tmp/backup-status.json")
    machine.copy_from_machine("/tmp/backup-status.json")
  '';
}
