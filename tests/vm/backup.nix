{ inputs }:
{ pkgs, lib, ... }:
let
  notification = import ../fixtures/notifications.nix { inherit pkgs; };
  notificationPackages = import ../../nix/notifications.nix {
    inherit pkgs inputs;
    caBundle = notification.ca;
  };
  targets = [
    "first"
    "second"
    "third"
  ];
in
{
  name = "restic-recovery";
  globalTimeout = 900;
  qemu.forceAccel = true;
  node.pkgsReadOnly = false;
  node.specialArgs = {
    inherit inputs;
    userName = "developer";
  };
  nodes.upstream = {
    imports = [ notification.server ];
    networking.firewall.enable = false;
    services.restic.server = {
      enable = true;
      extraFlags = [ "--no-auth" ];
    };
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
  nodes.machine = { pkgs, ... }: {
    # Leave enough time to observe an acquired remote lock before interrupting
    # the real Restic upload. Small recovery fixtures otherwise finish too fast.
    nixpkgs.overlays = [
      (_: prev: {
        restic = prev.symlinkJoin {
          name = "restic-paced-upload";
          paths = [ prev.restic ];
          nativeBuildInputs = [ prev.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/restic --add-flags '--limit-upload 512'
          '';
          meta.mainProgram = "restic";
        };
      })
    ];
    users.users.developer.isNormalUser = true;
    users.users.outsider.isNormalUser = true;
    site.containers.enable = true;
    security.pki.certificateFiles = [ notification.ca ];
    networking.nameservers = [ "192.168.1.2" ];
    networking.useDHCP = false;
    time.timeZone = "America/New_York";
    services.timesyncd.enable = false;
    virtualisation = {
      memorySize = 3072;
      cores = 2;
      emptyDiskImages = [ 2048 ];
      fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
    };
    imports = [
      inputs.impermanence.nixosModules.impermanence
      ../../profiles/laptop/persistence.nix
      ../../modules/services/containers.nix
      ../../modules/services/notifications.nix
      notification.credentials
      ../../modules/services/backup.nix
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.restic
      pkgs.python3
      pkgs.jq
    ];
    environment.etc = {
      "backup-test/password" = {
        text = "synthetic-password";
        mode = "0600";
      };
      "backup-test/environment".text = "";
    }
    // lib.genAttrs (map (name: "backup-test/${name}") targets) (name: {
      text = "rest:http://192.168.1.2:8000/${builtins.baseNameOf name}/";
    });
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
      targets = lib.genAttrs targets (name: {
        repositoryFile = "/etc/backup-test/${name}";
        passwordFile = "/etc/backup-test/password";
        environmentFile = "/etc/backup-test/environment";
        recoverStaleLocks = true;
        automatic = lib.mkIf (name == "first") {
          backupAttemptsPerWindow = 1;
          heavySpacingSeconds = 86400;
        };
        minimumIntervalSeconds.check = lib.mkIf (name == "first") 0;
      });
    };
  };
  testScript = builtins.readFile ./notifications.py + ''
    from datetime import timedelta
    import time

    upstream.start()
    upstream.wait_for_unit("restic-rest-server.service")
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop 'site-backup-*-automatic.timer'")
    notification_smoke(machine, upstream, "${notificationPackages.python}/bin/python3")
    machine.succeed("mkdir -p /persist/data/Cache; echo important > /persist/data/document; echo disposable > /persist/data/Cache/blob; systemd-tmpfiles --create")
    for target in ("first", "second", "third"):
        machine.succeed(f"RESTIC_PASSWORD_FILE=/etc/backup-test/password restic -r rest:http://192.168.1.2:8000/{target}/ init")

    def record(target, name):
        return json.loads(machine.succeed(f"cat /var/lib/site-backup-{target}/{name}.json"))

    def restore(target, destination):
        machine.succeed(f"RESTIC_PASSWORD_FILE=/etc/backup-test/password restic -r rest:http://192.168.1.2:8000/{target}/ restore latest --target {destination} --verify")
        machine.succeed(f"cmp /persist/data/document {destination}/data/document; test ! -e {destination}/data/Cache")

    def health():
        machine.succeed("systemctl start site-backup-status")
        return json.loads(machine.succeed("backup-status"))["repositories"]

    initial = health()
    assert all(value["backup"]["state"] == "pending" for value in initial.values()), initial
    deadline = initial["first"]["backup"]["dueAt"]
    machine.succeed(f"date -s @{deadline + 1}")
    overdue = health()
    assert overdue["first"]["backup"]["state"] == "stale", overdue
    assert overdue["first"]["check"]["state"] == "pending", overdue

    # At 13:00 Shanghai, activation leaves the next backup for the evening.
    machine.succeed("date -s '2027-03-15 05:00:00 UTC'; systemctl start site-backup-first-automatic")
    machine.succeed("RESTIC_PASSWORD_FILE=/etc/backup-test/password restic -r rest:http://192.168.1.2:8000/first/ snapshots --json | jq -e 'length == 0'")
    # A missed timer catches up inside the morning window, using Shanghai time
    # while the system clock is displayed in Virginia's timezone.
    machine.succeed("date -s '2027-03-16 03:00:00 UTC'; mkdir -p /var/lib/systemd/timers; touch -d '2027-03-15 00:00:00 UTC' /var/lib/systemd/timers/stamp-site-backup-first-automatic.timer; systemctl start site-backup-first-automatic.timer")
    machine.wait_until_succeeds("test -s /var/lib/site-backup-first/backup-success.json", timeout=90)
    machine.wait_until_succeeds("test $(systemctl show site-backup-first-automatic -p SubState --value) = dead", timeout=90)
    morning = record("first", "backup-success")
    machine.succeed("systemctl stop site-backup-first-automatic.timer; systemctl start site-backup-first-automatic")
    assert record("first", "backup-success") == morning
    restore("first", "/restore-morning")

    # Results remain local while the external notification channel is unavailable.
    upstream.succeed("echo 10000 > /run/notification-fixture/failures")
    upstream.succeed("mv /var/lib/restic/second /var/lib/restic/second-offline")
    machine.fail("systemctl start site-backup-second-backup")
    assert record("second", "backup-result")["result"] == "failure"
    assert health()["second"]["backup"]["state"] == "failed"
    upstream.succeed("mv /var/lib/restic/second-offline /var/lib/restic/second")
    machine.succeed("systemctl reset-failed site-backup-second-backup")
    for target in ("first", "second", "third"):
        machine.succeed(f"systemctl start site-backup-{target}-backup")
        assert record(target, "backup-success")["files"] == 2
        for operation in ("check", "restore-test", "maintenance"):
            machine.succeed(f"systemctl start site-backup-{target}-{operation}")
            assert record(target, operation + "-result")["result"] == "success"
        restore(target, "/restore-" + target)
    assert all(value["backup"]["state"] == "fresh" for value in health().values())

    # A second daily window gets its own recovery point, even less than 12h later.
    machine.succeed("date -s '2027-03-16 13:30:00 UTC'; echo evening > /persist/data/document; systemctl start site-backup-first-automatic")
    evening = record("first", "backup-success")
    assert evening["window"] != morning["window"]
    restore("first", "/restore-evening")

    # A selected nested mount reports a failure while preserving the last success.
    before = record("third", "backup-success")
    machine.succeed("mkdir -p /persist/data/mounted; mount -t tmpfs tmpfs /persist/data/mounted; echo external > /persist/data/mounted/document")
    machine.fail("systemctl start site-backup-third-backup")
    assert record("third", "backup-success") == before
    machine.succeed("umount /persist/data/mounted; systemctl reset-failed site-backup-third-backup; systemctl start site-backup-third-backup")
    restore("third", "/restore-retry")

    # Stop an upload only after its lock exists. Healthy transport lets Restic
    # release that lock while the runner continues draining its diagnostics.
    machine.succeed("dd if=/dev/urandom of=/persist/data/inflight bs=1M count=8 status=none; systemctl start --no-block site-backup-first-backup")
    upstream.wait_until_succeeds("test -n \"$(find /var/lib/restic/first/locks -type f -print -quit)\"", timeout=30)
    stopped_at = time.monotonic()
    machine.succeed("systemctl stop site-backup-first-backup", timeout=35)
    assert time.monotonic() - stopped_at < 30
    upstream.succeed("test -z \"$(find /var/lib/restic/first/locks -type f -print -quit)\"")
    assert record("first", "backup-result")["result"] == "interrupted"
    assert record("first", "backup-success") == evening

    # Losing the backend after acquiring a lock still allows bounded shutdown.
    # Another operation for the same repository skips immediately instead of queuing.
    machine.succeed("systemctl start --no-block site-backup-first-backup")
    upstream.wait_until_succeeds("test -n \"$(find /var/lib/restic/first/locks -type f -print -quit)\"", timeout=30)
    upstream.succeed("systemctl kill -s STOP restic-rest-server.service")
    machine.succeed("systemctl start site-backup-first-check", timeout=10)
    assert record("first", "check-result")["result"] == "skipped"
    machine.execute("systemctl poweroff --no-block", check_return=False, check_output=False)
    machine.wait_for_shutdown(timeout=timedelta(seconds=60))
    upstream.succeed("systemctl kill -s CONT restic-rest-server.service; echo 0 > /run/notification-fixture/failures")
    upstream.succeed("test -n \"$(find /var/lib/restic/first/locks -type f -print -quit)\"")
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl stop 'site-backup-*-automatic.timer'; date -s '2027-03-16 13:40:00 UTC'")
    assert record("first", "backup-result")["result"] == "interrupted"
    assert record("first", "backup-success") == evening
    assert health()["first"]["backup"]["state"] == "fresh"
    machine.succeed("rm /persist/data/inflight; systemctl start site-backup-first-backup")
    # A leftover shared backup lock permits another backup. The next exclusive
    # check exercises exit-11 recovery and removes that dead owner's lock.
    machine.succeed("systemctl start site-backup-first-check")
    assert record("first", "check-result")["result"] == "success"
    upstream.succeed("test -z \"$(find /var/lib/restic/first/locks -type f -print -quit)\"")
    restore("first", "/restore-after-reboot")
    latest = record("first", "backup-result")["id"]
    # Boot-time delivery and job completion both use the same latest-result queue.
    machine.wait_until_succeeds("test $(jq -r .id /var/lib/site-backup-first/backup-notification.json) = " + latest + " && jq -e '.deliveredChannels | index(\"bark\") != null' /var/lib/site-backup-first/backup-notification.json", timeout=180)
    for target in ("first", "second", "third"):
        machine.wait_until_succeeds(f"test -z \"$(find /var/lib/site-backup-{target} -name '*-pending.json' -print -quit)\"", timeout=180)
        machine.succeed(f"test $(stat -c %a /var/lib/site-backup-{target}) = 700")
    notifications = [json.loads(line) for line in upstream.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
    bodies = [str(event["body"]) for event in notifications]
    assert all(any(f"operation={operation}; result=success" in body for body in bodies) for operation in ("backup", "check", "restore-test", "maintenance"))
    machine.succeed("systemctl start site-backup-status; backup-status > /tmp/backup-status.json")
    machine.copy_from_machine("/tmp/backup-status.json")
    machine.shutdown()
    upstream.shutdown()
  '';
}
