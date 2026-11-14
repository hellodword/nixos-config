{ inputs }:
{
  pkgs,
  lib,
  nodes,
  ...
}:
let
  ssh = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  tls = import (pkgs.path + "/nixos/tests/nginx/proxyprotocol/snakeoil-certs.nix");
  cert = tls."*.test.nix".cert;
  key = tls."*.test.nix".key;
  python = pkgs.python3.withPackages (p: [
    p.pyyaml
    p.dnspython
    p.h2
  ]);
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../scripts/vps
      ../../scripts/network
      ../../workers
      ../../data/network
      ../../nix/vps.nix
      ../../modules/vps
      ../../profiles/vps
      ../../lib/nts-servers.nix
      ../../lib/service-hardening.nix
      ../../data/secrets/vps.example.yaml
      ../__init__.py
      ../fixtures
      ../integration/wrangler.py
    ];
  };
  keys = pkgs.runCommand "vps-public-test-keys" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    mkdir $out
    cp ${ssh.snakeOilEd25519PrivateKey} $out/ssh
    printf '%s\n' '${ssh.snakeOilEd25519PublicKey}' > $out/ssh.pub
    cp ${tls.ca.cert} $out/ca.crt
    printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE=' > $out/wg-client
    printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEI=' > $out/wg-server
    wg pubkey < $out/wg-client > $out/wg-client.pub
    wg pubkey < $out/wg-server > $out/wg-server.pub
  '';
  credentials = pkgs.runCommand "vps-public-test-context" { nativeBuildInputs = [ python ]; } ''
    mkdir $out
    PYTHONPATH=${source} python3 -m tests.fixtures.vps ${source} ${keys} $out
  '';
  metadata = {
    nodes = lib.genAttrs [ "edge" "west" ] (name: {
      address = if name == "edge" then "192.0.2.10" else "192.0.2.11";
      serverName = "${name}.test.nix";
      uefi = name == "west";
      dhcp = name == "west";
      gateway = "192.0.2.30";
      addresses = lib.optional (name == "edge") "192.0.2.10/24";
      nameservers = [
        "192.0.2.30#dns.test.nix"
        "192.0.2.31#dns.test.nix"
      ];
      sshHost = "deploy-${name}";
      sshServer = {
        rootAuthorizedKeys = [ ssh.snakeOilEd25519PublicKey ];
        port = if name == "edge" then 2222 else 22022;
      };
      udpPort = if name == "edge" then 20000 else 20001;
      release = "v1";
      certificateId = "fixture";
      web = lib.optionalAttrs (name == "west") { "app.test.nix" = "http://127.0.0.1:18090"; };
    });
  };
  sshConfig = pkgs.writeText "vps-maintenance-ssh.conf" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (_: node: ''
        Host ${node.sshHost}
          HostName ${node.address}
          Port ${toString node.sshServer.port}
          User root
          IdentityFile /root/.ssh/vps-deploy
          IdentitiesOnly yes
          ProxyCommand ${pkgs.netcat-openbsd}/bin/nc -x 192.0.2.30:1080 %h %p
      '') metadata.nodes
    )
  );
  fixture = "${pkgs.coreutils}/bin/env PYTHONPATH=${source} ${python}/bin/python3";
  testNetwork = {
    security.pki.certificateFiles = [ tls.ca.cert ];
    services.chrony.servers = lib.mkForce [ "nts.test.nix" ];
  };
  bootstrap =
    lib.mapAttrs (_: system: system.extendModules { modules = [ testNetwork ]; })
      (import ../../nix/vps.nix { inherit inputs metadata; }).bootstrap;
  images = lib.mapAttrs (_: system: system.config.system.build.image) bootstrap;
  systems = lib.genAttrs [ "v1" "v2" ] (
    release:
    (inputs.colmena.lib.makeHive (
      (import ../../nix/vps.nix {
        inherit inputs;
        metadata = metadata // {
          nodes = lib.mapAttrs (_: node: node // { inherit release; }) metadata.nodes;
        };
      }).hive
      // {
        defaults = { name, ... }: {
          imports = [
            testNetwork
            (import ./background.nix { scenario = "vps"; })
          ];
          environment.etc."vps-generation".text = release;
          systemd.services.application = lib.mkIf (name == "west") {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${python}/bin/python3 -m http.server 18090 --bind 127.0.0.1 --directory ${pkgs.writeTextDir "index.html" "vps application"}";
          };
        };
      }
    )).toplevel
  );
  # These node modules describe QEMU hardware only. Guests boot the same raw
  # bootstrap images delivered to VPS, and are controlled over authenticated SSH.
  node = name: {
    virtualisation = {
      memorySize = 512;
      cores = 1;
      useBootLoader = true;
      useEFIBoot = name == "west";
      efi.keepVariables = false;
      directBoot.enable = false;
      installBootLoader = false;
      useDefaultFilesystems = false;
      diskImage = "./root.qcow2";
      mountHostNixStore = false;
      writableStore = false;
      sharedDirectories = lib.mkForce { };
      fileSystems = lib.mkForce {
        "/" = {
          device = "tmpfs";
          fsType = "tmpfs";
        };
      };
      # The test VLAN is the sole NIC, so the installed system sees eth0.
      qemu.networkingOptions = lib.mkForce [ ];
    };
  };
  # Colmena builds a profile link on the controller, then copies and activates
  # the prebuilt guest system. The guest store needs only runtime closures.
  hive = pkgs.writeText "vps-test-hive.nix" ''
    let
      inputs.nixpkgs-remote = { lib = import ${pkgs.path}/lib; legacyPackages.x86_64-linux = import ${pkgs.path} { system = "x86_64-linux"; }; };
      release = builtins.getEnv "VPS_RELEASE";
      metadata = builtins.fromJSON ${builtins.toJSON (builtins.toJSON metadata)};
      vps = import ${source}/nix/vps.nix {
        inherit inputs;
        directory = "/run/vps";
        metadata = metadata // { nodes = builtins.mapAttrs (_: node: node // { inherit release; }) metadata.nodes; };
      };
      systems = {
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: _: ''
            ${name} = {
              ${lib.concatMapStringsSep "\n"
                (
                  release:
                  let
                    system = systems.${release}.${name};
                  in
                  ''
                    ${release} = builtins.derivation {
                      name = "${system.name}";
                      system = "x86_64-linux";
                      builder = builtins.storePath "${pkgs.coreutils}" + "/bin/ln";
                      args = [ "-s" (builtins.storePath "${system}") (builtins.placeholder "out") ];
                    };
                  ''
                )
                [
                  "v1"
                  "v2"
                ]
              }
            };
          '') metadata.nodes
        )}
      };
    in vps.hive // {
      defaults = { lib, name, ... }: {
        options.system.build.toplevel = lib.mkOption {
          apply = _: systems.''${name}.''${release};
        };
      };
    }
  '';
  socks = pkgs.writeText "vps-upstream-socks.json" (
    builtins.toJSON {
      inbounds = [
        {
          type = "socks";
          listen = "192.0.2.30";
          listen_port = 1080;
        }
      ];
      outbounds = [
        {
          type = "direct";
          inet4_bind_address = "198.51.100.30";
        }
      ];
    }
  );
in
{
  name = "vps-deployment-and-exits";
  globalTimeout = 1800;
  qemu.forceAccel = true;
  defaults.networking.useDHCP = false;
  nodes = {
    edge = node "edge";
    west = node "west";
    controller = {
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          no-resolv = true;
          port = 0;
          dhcp-range = "192.0.2.0,static,255.255.255.0";
          dhcp-host = "${
            (import (pkgs.path + "/nixos/lib/qemu-common.nix") { inherit (pkgs) lib stdenv; }).qemuNicMac 1
              nodes.west.virtualisation.test.nodeNumber
          },192.0.2.11";
          dhcp-option = [
            "option:router,192.0.2.30"
            "option:dns-server,192.0.2.30"
          ];
        };
      };
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.additionalPaths = [
        pkgs.path
        credentials
        hive
      ];
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        substituters = lib.mkForce [ ];
        max-jobs = 1;
      };
      networking.firewall.enable = false;
      # sing-box schedules health probes while the default interface is online.
      networking.defaultGateway = "192.0.2.10";
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.0.2.30";
          prefixLength = 24;
        }
        {
          address = "198.51.100.30";
          prefixLength = 32;
        }
        {
          address = "192.0.2.31";
          prefixLength = 24;
        }
      ];
      environment.systemPackages = [
        python
        pkgs.gitMinimal
        (import ../../nix/wrangler.nix { inherit pkgs; })
        pkgs.curl
        pkgs.nftables
        inputs.nixpkgs.legacyPackages.x86_64-linux.sing-box
        pkgs.wireguard-tools
        inputs.colmena.packages.x86_64-linux.default
      ];
      users.users.publisher.isNormalUser = true;
      services.chrony = {
        enable = true;
        enableNTS = true;
        servers = lib.mkForce [ ];
        extraConfig = ''
          local stratum 1
          allow 192.0.2.0/24
          ntsservercert ${cert}
          ntsserverkey ${key}
        '';
      };
      systemd.services.vps-dns-0 = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${fixture} -m tests.fixtures.vps_dns 0 ${cert} ${key}";
      };
      systemd.services.vps-dns-1 = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${fixture} -m tests.fixtures.vps_dns 1 ${cert} ${key}";
      };
      systemd.services.certificate-fixture = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${python}/bin/python3 ${../fixtures/vps_certificate.py} ${cert} ${key}";
      };
      systemd.services.origin = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${fixture} -m tests.fixtures.vm_network_fixture host";
      };
      systemd.services.socks = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${socks}";
      };
      systemd.services.wg-fixture = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [
          pkgs.iproute2
          pkgs.wireguard-tools
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ip link add wg-fixture type wireguard
          ip address add 10.88.0.1/24 dev wg-fixture
          wg set wg-fixture private-key ${keys}/wg-server listen-port 51820 peer "$(cat ${keys}/wg-client.pub)" allowed-ips 10.88.0.2/32
          ip link set wg-fixture up
        '';
      };
      services.openvpn.servers.fixture.config = ''
        dev tun
        proto tcp-server
        port 1194
        server 10.89.0.0 255.255.255.0
        topology subnet
        ca ${tls.ca.cert}
        cert ${cert}
        key ${key}
        dh none
        verify-client-cert none
        username-as-common-name
        auth-user-pass-verify ${pkgs.writeShellScript "fixture-auth" ''test "$username:$password" = fixture:fixture''} via-env
        script-security 3
        data-ciphers AES-256-GCM:AES-128-GCM
        keepalive 10 60
      '';
    };
  };
  testScript = ''
    import datetime
    import json
    from pathlib import Path
    import re
    import shlex
    import subprocess

    controller.start()
    controller.wait_for_unit("dnsmasq.service")
    controller.wait_for_open_port(853, addr="192.0.2.30", timeout=30)
    controller.wait_for_open_port(4460, addr="192.0.2.30", timeout=30)
    controller.wait_for_open_port(1080, addr="192.0.2.30", timeout=30)
    controller.succeed("mkdir -m 700 -p /root/.ssh /run/vps; cp -r ${credentials}/. /run/vps/; chmod -R u+w /run/vps; install -m 600 ${keys}/ssh /root/.ssh/vps-deploy; install -m 600 ${sshConfig} /root/.ssh/config")
    addresses = {"edge": "192.0.2.10", "west": "192.0.2.11"}
    ssh_hosts = ${builtins.toJSON (lib.mapAttrs (_: node: node.sshHost) metadata.nodes)}
    ssh_ports = ${builtins.toJSON (lib.mapAttrs (_: node: node.sshServer.port) metadata.nodes)}
    images = ${builtins.toJSON (lib.mapAttrs (_: image: "${image}/nixos.img") images)}

    def remote(machine, command):
        return f"ssh -o BatchMode=yes -o ConnectTimeout=3 {ssh_hosts[machine.name]} " + shlex.quote("set -euo pipefail; " + command)

    def succeed(machine, command, timeout=60):
        return controller.succeed(remote(machine, command), timeout=timeout)

    def wait_unit(machine, unit):
        controller.wait_until_succeeds(remote(machine, "systemctl is-active " + unit), timeout=120)

    def poweroff(machine):
        # Return the SSH acknowledgement before shutdown closes its connection.
        succeed(machine, "systemd-run --unit=vps-test-poweroff --on-active=2s --timer-property=AccuracySec=100ms systemctl poweroff")
        machine.wait_for_shutdown(timeout=datetime.timedelta(seconds=60))

    def powercycle(machine):
        poweroff(machine)
        machine.start()
        wait_unit(machine, "sshd.service")

    with subtest("BIOS and UEFI bootstrap images start at 512 MiB with a grown root and disk swap"):
        for machine in (edge, west):
            image = images[machine.name]
            print(f"{machine.name}: raw image {Path(image).stat().st_size} bytes")
            subprocess.run(["${pkgs.qemu_test}/bin/qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", image,
                            str(machine.state_dir / "root.qcow2"), "10G"], check=True)
            machine.start()
            address = addresses[machine.name]
            scan = f"ssh-keyscan -p {ssh_ports[machine.name]} -t ed25519 {address} > /root/.ssh/{machine.name}.pub"
            controller.wait_until_succeeds(scan, timeout=120)
            fingerprint = controller.succeed(f"ssh-keygen -lf /root/.ssh/{machine.name}.pub").split()[1]
            machine.wait_for_console_text(re.escape(fingerprint), timeout=30)
            controller.succeed(f"cat /root/.ssh/{machine.name}.pub >> /root/.ssh/known_hosts")
            wait_unit(machine, "multi-user.target")
            succeed(machine, "swapon --show --noheadings | grep /var/lib/swapfile")
            root_bytes = int(succeed(machine, "df --output=size -B1 / | tail -n 1"))
            assert root_bytes > 9 * 1024**3, (machine.name, root_bytes)
            print(succeed(machine, "free -m; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS; df -h / /boot; ip -4 address show eth0"))
    with subtest("System DNS uses cached DoT and time is authenticated with NTS"):
        for machine in (edge, west):
            controller.wait_until_succeeds(remote(machine, "chronyc -n ntpdata 192.0.2.30 | grep -Eq '^Authenticated *: Yes$'"), timeout=90)
            print(succeed(machine, "chronyc -n sources; chronyc -n authdata; resolvectl status"))
            succeed(machine, "getent ahostsv4 cached-" + machine.name + ".fixture.example")
            count = controller.succeed("cat /run/vps-dns-*.jsonl | grep -c cached-" + machine.name)
            succeed(machine, "getent ahostsv4 cached-" + machine.name + ".fixture.example")
            repeated = controller.succeed("cat /run/vps-dns-*.jsonl | grep -c cached-" + machine.name)
            assert repeated == count, (
                controller.succeed("cat /run/vps-dns-*.jsonl"),
                succeed(machine, "resolvectl statistics; resolvectl show-cache"),
            )
        controller.succeed("systemctl stop vps-dns-0.service")
        for machine in (edge, west):
            controller.wait_until_succeeds(remote(machine, "getent ahostsv4 dot-failover.fixture.example"), timeout=45)
        controller.succeed("grep dot-failover /run/vps-dns-1.jsonl; systemctl start vps-dns-0.service")
    with subtest("Wrangler bundles both Workers with isolated files and persistent account state"):
        controller.succeed("runuser -u publisher -- ${python}/bin/python3 ${source}/tests/integration/wrangler.py", timeout=120)
    def deploy(release, goal, target="edge,west"):
        for name in target.split(","):
            status, output = controller.execute(f"VPS_RELEASE={release} colmena -f ${hive} apply {goal} --on {name} --parallel 1 --no-substitute", timeout=300)
            if status:
                print(controller.succeed("free -m; df -h / /nix/store; journalctl -b -u nix-daemon -u systemd-oomd --no-pager; dmesg | tail -n 40"))
                print(controller.execute(remote({"edge": edge, "west": west}[name], "journalctl -b -u site-vps-proxy -u site-vps-certificate -u nginx --no-pager -n 80"))[1])
                raise RuntimeError(f"{name}: Colmena {goal} exited {status}: {output}")
    with subtest("Colmena deploys through SSH aliases, identities, ports and a SOCKS proxy"):
        deploy("v1", "switch")
    for machine in (edge, west):
        wait_unit(machine, "site-vps-proxy.service")
        succeed(machine, "test $(stat -c %a /var/lib/site-vps/releases/v1/proxy.json) = 600")
    provider = json.loads(controller.succeed("cat /run/vps/provider-v1.json"))
    wait_unit(west, "nginx.service")
    assert controller.succeed("curl --fail --cacert ${tls.ca.cert} --resolve app.test.nix:443:192.0.2.11 https://app.test.nix").strip() == "vps application"
    def request(path, expected, domain="origin.fixture.example"):
        config = {"inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 11080}], "outbounds": [path]}
        config["outbounds"][0]["tls"]["certificate_path"] = "${tls.ca.cert}"
        controller.succeed("printf %s " + shlex.quote(json.dumps(config)) + " > /run/client.json")
        controller.succeed("systemctl stop vps-client.service || true; systemd-run --unit=vps-client --collect sing-box run -c /run/client.json")
        controller.wait_for_open_port(11080)
        result = controller.succeed("curl --retry 5 --retry-all-errors --retry-delay 1 --max-time 10 --fail -sS --socks5-hostname 127.0.0.1:11080 http://" + domain + ":18080/").strip()
        assert result == expected, (path["tag"], result, expected)
    with subtest("Each entry reaches native and userspace exits through both protocols"):
        expected = {"edge-native": "192.0.2.10", "west-native": "192.0.2.11", "us": "198.51.100.30", "west-wg": "10.88.0.2", "west-openvpn": "10.89.0.2"}
        for entry in ("edge", "west"):
            for exit_id, address in expected.items():
                carriers = ["edge", "west"] if exit_id == "us" else ["edge" if exit_id == "edge-native" else "west"]
                for carrier in carriers:
                    for protocol in ("trojan", "hysteria2"):
                        path = next(p for p in provider["outbounds"] if p["tag"] == f"path-{entry}-{carrier}-{exit_id}-{protocol}")
                        request(path, address)
    with subtest("Exit DNS survives an unavailable resolver and a resolver returning SERVFAIL"):
        path = next(p for p in provider["outbounds"] if p["tag"] == "path-edge-west-us-trojan")
        controller.succeed("systemctl stop vps-dns-0.service")
        request(path, "198.51.100.30", "transport.fixture.example")
        controller.succeed("systemctl start vps-dns-0.service")
        request(path, "198.51.100.30", "sf.fixture.example")
        controller.succeed("grep sf.fixture.example /run/vps-dns-1.jsonl")
    with subtest("Path selection preserves healthy connections and survives carrier loss in auto mode"):
        controller.succeed("systemctl stop vps-client.service")
        controller.succeed("systemd-run --unit=vps-client --collect sing-box run -c /run/vps/failover.json")
        controller.wait_for_open_port(19090)

        def select_path(name):
            controller.succeed("curl --fail -sS -X PUT -H 'Content-Type: application/json' --data " +
                               shlex.quote(json.dumps({"name": name})) + " http://127.0.0.1:19090/proxies/exit-us")

        select_path("path-west-west-us-trojan")
        stream = """
    import json, socket, time
    from pathlib import Path
    from tests.fixtures.network_fixture import read_exact
    with socket.create_connection(('127.0.0.1', 11080), timeout=3) as connection:
        connection.sendall(bytes.fromhex('050100'))
        assert read_exact(connection, 2) == bytes.fromhex('0500')
        connection.sendall(bytes.fromhex('05010001c633641e46a2'))
        assert read_exact(connection, 4) == bytes.fromhex('05000001')
        read_exact(connection, 6)
        for count in range(1000):
            connection.sendall(b'keepalive\\n')
            assert connection.recv(100).strip() == b'198.51.100.30'
            Path('/run/stream-next').write_text(str(count))
            Path('/run/stream-next').replace('/run/stream-count')
            time.sleep(0.1)
    """
        controller.succeed("printf %s " + shlex.quote(stream) + " > /run/stream.py")
        controller.succeed("systemd-run --unit=vps-stream --collect ${fixture} /run/stream.py")
        controller.wait_until_succeeds("test -s /run/stream-count")
        count = int(controller.succeed("cat /run/stream-count"))
        select_path("path-edge-edge-us-trojan")
        controller.wait_until_succeeds(f"test $(cat /run/stream-count) -gt {count + 3}")
        controller.succeed("systemctl stop vps-stream.service")
        select_path("path-west-west-us-trojan")
        poweroff(west)
        controller.fail("curl --max-time 5 --fail -sS --socks5-hostname 127.0.0.1:11080 http://198.51.100.30:18080/")
        selected = json.loads(controller.succeed("curl --fail -sS http://127.0.0.1:19090/proxies/exit-us"))
        assert selected["now"] == "path-west-west-us-trojan", selected
        select_path("exit-us-auto")
        controller.wait_until_succeeds("test \"$(curl --max-time 5 --fail -sS --socks5-hostname 127.0.0.1:11080 http://198.51.100.30:18080/)\" = 198.51.100.30", timeout=45)
        west.start()
        wait_unit(west, "site-vps-proxy.service")
    with subtest("A failed certificate refresh retains the active pair"):
        previous = succeed(west, "readlink /var/lib/site-vps-certificate/fixture/current")
        controller.succeed("touch /run/certificate-unavailable")
        controller.fail(remote(west, "systemctl start site-vps-certificate.service"))
        assert succeed(west, "readlink /var/lib/site-vps-certificate/fixture/current") == previous
        controller.succeed("rm /run/certificate-unavailable")
    with subtest("Test, switch, reboot and rollback retain the required credentials"):
        deploy("v2", "test", "west")
        wait_unit(west, "site-vps-proxy.service")
        assert succeed(west, "cat /etc/vps-generation") == "v2"
        assert succeed(west, "cat /nix/var/nix/profiles/system/etc/vps-generation") == "v1"
        next_provider = json.loads(controller.succeed("cat /run/vps/provider-v2.json"))
        next_path = next(p for p in next_provider["outbounds"] if p["tag"] == "path-edge-west-west-native-trojan")
        request(next_path, "192.0.2.11")
        deploy("v2", "switch", "west")
        powercycle(west)
        wait_unit(west, "site-vps-proxy.service")
        request(next_path, "192.0.2.11")
        succeed(west, "nix-env -p /nix/var/nix/profiles/system --rollback; /nix/var/nix/profiles/system/bin/switch-to-configuration switch")
        wait_unit(west, "site-vps-proxy.service")
        assert succeed(west, "cat /etc/vps-generation") == "v1"
        old_path = next(p for p in provider["outbounds"] if p["tag"] == "path-edge-west-west-native-trojan")
        request(old_path, "192.0.2.11")
        succeed(west, "test -f /var/lib/site-vps/releases/v1/proxy.json; test -f /var/lib/site-vps/releases/v2/proxy.json")
    powercycle(edge)
    wait_unit(edge, "site-vps-proxy.service")
    for machine in (edge, west):
        print(succeed(machine, "df -h / /boot; swapon --show"))
        poweroff(machine)
  '';
}
