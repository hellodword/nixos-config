{ inputs }:
{ pkgs, lib, ... }:
let
  credentials = pkgs.writeText "files-test-credentials.yaml" ''
    files:
      certificateNames: [files.test, localhost, 192.168.1.2, 127.0.0.1]
  '';
in
{
  name = "file-services";
  qemu.forceAccel = true;
  nodes.server = {
    imports = [
      ../../modules/core/storage.nix
      ../../modules/services/containers.nix
      ../../modules/services/files.nix
      (import ./background.nix { scenario = "files"; })
    ];
    _module.args.userName = "developer";
    users.users.developer.isNormalUser = true;
    site.containers.enable = true;
    site.files = {
      enable = true;
      user = "developer";
      adminPasswordFile = "/run/files-fixture/admin";
      userPasswordFile = "/run/files-fixture/user";
      certificateConfigFile = "/run/files-fixture/certificate.yaml";
    };
    system.activationScripts.files-fixture.text = ''
      install -d -m 0700 /run/files-fixture
      printf 'admin-test-password' > /run/files-fixture/admin
      printf 'user-test-password' > /run/files-fixture/user
      cp ${credentials} /run/files-fixture/certificate.yaml
    '';
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    environment.systemPackages = [ pkgs.curl ];
    networking.firewall.allowedTCPPorts = [
      445
      8443
      8444
    ];
  };
  nodes.client = {
    networking.hosts."192.168.1.2" = [ "files.test" ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.samba
    ];
    virtualisation.memorySize = 512;
  };
  testScript = ''
    import json
    import shlex

    start_all()
    server.wait_for_unit("site-files-browser.service")
    server.wait_for_unit("site-files-smb.service")
    server.wait_for_unit("docker.service")
    server.succeed("site-files-certificate")
    server.wait_for_open_port(8443)
    client.succeed("cat > /tmp/ca.crt <<'CERT'\n" + server.succeed("cat /var/lib/site-files/ca.crt") + "CERT")
    base = "curl --fail --silent --show-error --cacert /tmp/ca.crt "
    root = "/home/developer/Downloads/dufs"

    def request(args, path="/", port=8443):
        return client.succeed(base + args + " " + shlex.quote(f"https://files.test:{port}{path}"))

    def login(account, password):
        request(f"-c /tmp/{account}.cookies -F act=login -F uname={account} -F cppwd={password} -F uhash=x")
        client.succeed(f"test -s /tmp/{account}.cookies")

    with subtest("browser sessions and WebDAV share the file tree"):
        for account, path in (("admin", "/"), ("user", "/user/")):
            login(account, account + "-test-password")
            request(f"-b /tmp/{account}.cookies -X PUT -H 'Content-Type: text/plain' --data 'browser upload'", path + "browser.txt")
            assert request(f"-b /tmp/{account}.cookies", path + "browser.txt") == "browser upload"
            auth = f"-u {account}:{account}-test-password"
            request(auth + " -X MKCOL", path + "webdav")
            request(auth + " -X PUT --data 'WebDAV upload'", path + "webdav/file.txt")
            assert request(auth, path + "webdav/file.txt") == "WebDAV upload"
            request(auth + " -X PROPFIND -H 'Depth: 1'", path + "webdav/")
            request(auth + " -X MOVE -H 'Destination: https://files.test:8443" + path + "webdav/moved.txt'", path + "webdav/file.txt")
            request(auth + " -X DELETE", path + "webdav/moved.txt")
        server.succeed("systemctl restart site-files-accounts")
        server.wait_for_unit("site-files-browser.service")
        client.wait_until_succeeds(base + "-b /tmp/admin.cookies https://files.test:8443/browser.txt")
        server.succeed("printf 'changed-test-password' > /run/files-fixture/user; systemctl restart site-files-accounts")
        server.wait_for_unit("site-files-browser.service")
        client.wait_until_succeeds(base + "-u user:changed-test-password https://files.test:8443/user/browser.txt")
        # A credential change revokes sessions issued under the old account set.
        status = client.succeed("curl --silent --show-error --cacert /tmp/ca.crt -b /tmp/user.cookies -w '%{http_code}' -o /tmp/old-session https://files.test:8443/user/browser.txt")
        assert status in ("401", "403"), status
        login("user", "changed-test-password")
        assert request("-b /tmp/user.cookies", "/user/browser.txt") == "browser upload"

    with subtest("SMB chooses the authenticated user's root"):
        client.succeed("printf 'SMB upload' > /tmp/input.txt")
        for account, password, directory in (("admin", "admin-test-password", root),
                                              ("user", "changed-test-password", root + "/user")):
            smb = "smbclient --configfile=/dev/null //server/files --client-protection=encrypt -U "
            connection = smb + shlex.quote(account + "%" + password) + " -c "
            client.succeed(connection + shlex.quote("put /tmp/input.txt smb.txt; get smb.txt /tmp/output.txt; mkdir folder"))
            client.succeed("cmp /tmp/input.txt /tmp/output.txt")
            assert server.succeed(f"cat {directory}/smb.txt") == "SMB upload"
            client.succeed(connection + shlex.quote("rename smb.txt renamed.txt; del renamed.txt; rmdir folder"))
        server.succeed(f"runuser -u developer -- sh -c 'printf local > {root}/local.txt; printf local > {root}/user/local.txt'")
        assert request("-u admin:admin-test-password", "/local.txt") == "local"
        assert request("-u user:changed-test-password", "/user/local.txt") == "local"

    def share(argument):
        server.succeed("systemd-run --unit=files-share --property=User=developer --property=WorkingDirectory=/home/developer/share "
                       "/run/current-system/sw/bin/httpserver " + argument)
        client.wait_until_succeeds(base + "https://files.test:8444/", timeout=90)
        return server.succeed("cat /run/site-httpserver/share-*/container-id").strip()

    def stop_share(container):
        server.succeed("systemctl kill --kill-whom=main --signal=SIGINT files-share.service")
        server.wait_until_succeeds("test ! -S /run/site-httpserver/socket/backend.sock")
        server.wait_until_succeeds(f"test -z \"$(docker ps -aq --no-trunc --filter id={container})\"")
        server.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value files-share)\" = inactive")

    with subtest("foreground temporary shares serve files with their MIME type"):
        server.succeed("install -d -o developer -g users /home/developer/share; printf '%%PDF-1.4 test' > /home/developer/share/report.pdf; printf image > /home/developer/share/image.png")
        for argument in ("", "/home/developer/share", "/home/developer/share/report.pdf"):
            container = share(argument)
            assert request("-I", "/report.pdf", 8444).lower().find("content-type: application/pdf") >= 0
            assert request("", "/report.pdf", 8444) == "%PDF-1.4 test"
            if not argument.endswith(".pdf"):
                assert "content-type: image/png" in request("-I", "/image.png", 8444).lower()
            stop_share(container)

    with subtest("HTTPS diagnostics describe the completed request"):
        body = "x" * 5000
        request("-u admin:admin-test-password -X PUT -H 'Content-Type: text/plain' -H 'X-Trace: files-vm' --data " + shlex.quote(body), "/logged.txt?probe=1")
        server.wait_until_succeeds("journalctl -u site-files-web -o cat --no-pager | grep -F '/logged.txt?probe=1'")
        events = [json.loads(line)["MESSAGE"] for line in server.succeed("journalctl -u site-files-web --all -o json --no-pager").splitlines()]
        records = [json.loads(message) for message in events if message.startswith('{')]
        event = next(event for event in reversed(records) if event.get("method") == "PUT" and event.get("path") == "/logged.txt")
        assert event["url"].endswith("?probe=1") and int(event["status"]) in (200, 201), event
        assert "x-trace" in event["request_headers"].lower() and event["response_headers"], event
        assert event["request_body"] == body[:4096], event
  '';
}
