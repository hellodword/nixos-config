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
      pkgs.openssl
      pkgs.chromium
      (pkgs.python3.withPackages (p: [ p.playwright ]))
    ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    import runpy
    runtime = runpy.run_path("${./runtime.py}")
    with runtime["scenario"]([server, client], lambda: [
        (server, "files", "systemctl --failed --no-pager; journalctl -b -u 'site-files-*' -u 'site-httpserver*' -n 120 --no-pager"),
        (client, "client", "ls -l /tmp; ip address; ip route; journalctl -b -u files-enrollment --no-pager -n 80"),
    ]):
        import json
        import shlex

        start_all()
        server.wait_for_unit("site-files-browser.service")
        server.wait_for_unit("site-files-smb.service")
        server.wait_for_unit("docker.service")
        server.succeed("site-files-certificate")
        server.succeed("site-files-client issue workstation")
        server.wait_for_open_port(8443)
        client.succeed("cat > /tmp/ca.crt <<'CERT'\n" + server.succeed("cat /var/lib/site-files/ca.crt") + "CERT")
        for source, destination in (("certificate.crt", "device.crt"), ("key.pem", "device.key")):
            client.succeed("umask 077; cat > /tmp/" + destination + " <<'CERT'\n" + server.succeed("cat /var/lib/site-files/private/clients/devices/workstation/" + source) + "CERT")
        base = "curl --max-time 30 --fail --silent --show-error --cacert /tmp/ca.crt "
        identity = "--cert /tmp/device.crt --key /tmp/device.key "
        root = "/home/developer/Downloads/dufs"

        def request(args, path="/", port=8443):
            return client.succeed(base + (identity if port == 8443 else "") + args + " " + shlex.quote(f"https://files.test:{port}{path}"))

        with subtest("HTTP redirects preserve the actual port and TLS authenticates devices"):
            for port in (8443, 8444):
                headers = client.succeed(f"curl --silent --show-error -I 'http://files.test:{port}/user/?a=1'").lower()
                assert f"location: https://files.test:{port}/user/?a=1" in headers, headers
                status = client.succeed(f"curl --silent --show-error -X POST -o /dev/null -w '%{{http_code}}' http://files.test:{port}/")
                assert status == "405", status
            client.fail(base + "https://files.test:8443/")
            # A Host header for the other port cannot select its TLS policy.
            client.fail(base + "-H 'Host: files.test:8444' https://files.test:8443/")

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
            client.wait_until_succeeds(base + identity + "-b /tmp/admin.cookies https://files.test:8443/browser.txt")
            server.succeed("printf 'changed-test-password' > /run/files-fixture/user; systemctl restart site-files-accounts")
            server.wait_for_unit("site-files-browser.service")
            client.wait_until_succeeds(base + identity + "-u user:changed-test-password https://files.test:8443/user/browser.txt")
            # A credential change revokes sessions issued under the old account set.
            status = client.succeed("curl --max-time 30 --silent --show-error --cacert /tmp/ca.crt " + identity + "-b /tmp/user.cookies -w '%{http_code}' -o /tmp/old-session https://files.test:8443/user/browser.txt")
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
                path = "/" if argument.endswith(".pdf") else "/report.pdf"
                assert "content-type: application/pdf" in request("-I", path, 8444).lower()
                assert request("", path, 8444) == "%PDF-1.4 test"
                assert request("-H 'Range: bytes=0-3'", path, 8444) == "%PDF"
                if not argument.endswith(".pdf"):
                    assert "content-type: image/png" in request("-I", "/image.png", 8444).lower()
                stop_share(container)

        with subtest("browser enrollment downloads an encrypted device bundle"):
            server.succeed("site-files-client issue phone")
            server.succeed("printf 'export-test-password\\nexport-test-password\\n' | setsid --fork --wait env SUDO_UID=$(id -u developer) SUDO_GID=$(id -g developer) site-files-client export phone --output /home/developer/share/phone.zip", timeout=30)
            container = share("--code Enrollment-42 /home/developer/share/phone.zip")
            client.succeed("systemd-run --unit=files-enrollment --setenv=PATH=/run/current-system/sw/bin python3 ${./files-browser.py} ${pkgs.chromium}/bin/chromium")
            client.wait_until_succeeds("test -e /tmp/device-connection-ready || ! systemctl is-active --quiet files-enrollment", timeout=90)
            client.succeed("test -e /tmp/device-connection-ready")
            output = server.succeed("journalctl -u files-share --all -o cat --no-pager")
            assert "https://192.168.1.2:8444/" in output, output
            fingerprint = server.succeed("${pkgs.openssl}/bin/openssl x509 -in /var/lib/site-files/server.crt -noout -sha256 -fingerprint").strip().split("=", 1)[1]
            assert fingerprint in output, output
            stop_share(container)
            server.succeed("site-files-client revoke phone")
            client.wait_until_succeeds("! systemctl is-active --quiet files-enrollment", timeout=130)
            client.succeed("test \"$(systemctl show -p ExecMainStatus --value files-enrollment)\" = 0")
            server.succeed("systemctl restart site-files-web")
            assert request("-b /tmp/user.cookies", "/user/browser.txt") == "browser upload"
            assert "phone\trevoked" in server.succeed("site-files-client list")
            status = client.succeed("curl --silent --show-error --cacert /tmp/ca.crt --cert-type P12 --cert /tmp/phone.p12:export-test-password -o /dev/null -w '%{http_code}' https://files.test:8443/")
            assert status == "403", status
            assert request("-b /tmp/user.cookies", "/user/browser.txt") == "browser upload"

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
