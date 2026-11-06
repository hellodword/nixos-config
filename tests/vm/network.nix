{ inputs }:
{ pkgs, lib, ... }:
let
  notification = import ../fixtures/notifications.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (p: [
    p.dnspython
    p.h2
  ]);
  # Public, deliberately non-secret nixpkgs test CA/keys, never production input.
  certificates = import (pkgs.path + /nixos/tests/nginx/proxyprotocol/snakeoil-certs.nix);
  cert = certificates."*.test.nix".cert;
  key = certificates."*.test.nix".key;
  fixtures = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py") ../fixtures;
  };
  fixture = "${pkgs.coreutils}/bin/env PYTHONPATH=${fixtures} ${python}/bin/python3 -m fixtures.vm_network_fixture";
  hyConfig = pkgs.writeText "synthetic-hysteria-server.json" (
    builtins.toJSON {
      log.level = "warn";
      dns.servers = [
        {
          type = "udp";
          tag = "fixture";
          server = "127.0.0.1";
          server_port = 15353;
        }
      ];
      inbounds = [
        {
          type = "hysteria2";
          listen = "::";
          listen_port = 4443;
          users = [ { password = "public-test-fixture-only"; } ];
          tls = {
            enabled = true;
            certificate_path = "${cert}";
            key_path = "${key}";
          };
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "direct";
        }
      ];
      route = {
        final = "direct";
        default_domain_resolver = "fixture";
      };
    }
  );
  upstreams = base: [
    {
      protocol = "tls";
      address = "192.168.1.20";
      port = base;
      serverName = "dns.test.nix";
    }
    {
      protocol = "https";
      address = "192.168.1.20";
      port = base + 1;
      serverName = "dns.test.nix";
    }
  ];
  notificationNode = proxy: address: {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      ../../profiles/laptop/persistence.nix
      ../../modules/network
      ../../modules/services/containers.nix
      ../../modules/services/notifications.nix
      notification.credentials
    ];
    _module.args.userName = "developer";
    users.users.developer.isNormalUser = true;
    virtualisation.memorySize = lib.mkForce 2048;
    virtualisation.emptyDiskImages = [ 2048 ];
    virtualisation.fileSystems."/persist" = {
      device = "/dev/vdb";
      fsType = "ext4";
      autoFormat = true;
      neededForBoot = true;
    };
    site.containers = {
      enable = true;
    };
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
    networking.defaultGateway = "192.168.1.20";
    environment.etc."test/provider.json".text = builtins.toJSON {
      outbounds = [
        {
          type = "hysteria2";
          tag = "synthetic";
          server = "192.168.1.20";
          server_port = 4443;
          password = "public-test-fixture-only";
          tls = {
            enabled = true;
            server_name = "dns.test.nix";
            certificate_path = "${certificates.ca.cert}";
          };
        }
      ];
    };
    site.network = {
      dns.enable = true;
      singBox.enable = proxy;
      providerFile = "/etc/test/provider.json";
      dnsPolicy = {
        caStore = "${certificates.ca.cert}";
        groups = {
          cn.upstreams = upstreams 24001;
          global.upstreams = upstreams 24003;
        };
      };
    };
  };

in
{
  name = "mullvad-lockdown-and-shared-dns";
  globalTimeout = 1500;
  qemu.forceAccel = true;
  node.specialArgs = { inherit inputs; };
  defaults = {
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = lib.mkForce false;
    networking.extraHosts = "192.168.1.30 headscale.test.nix";
    security.pki.certificateFiles = [
      certificates.ca.cert
      notification.ca
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
      pkgs.netcat-openbsd
      pkgs.nftables
      pkgs.tcpdump
      pkgs.wireguard-tools
      python
    ];
  };
  nodes = {
    dnsOnly = notificationNode false "192.168.1.11";
    dnsProxy = notificationNode true "192.168.1.12";
    client = {
      virtualisation.memorySize = lib.mkForce 3072;
      imports = [
        inputs.impermanence.nixosModules.impermanence
        ../../profiles/laptop/persistence.nix
        ../../modules/network
        ../../modules/network/connections.nix
        ../../modules/services/containers.nix
        ../../modules/services/notifications.nix
        notification.credentials
      ];
      _module.args.userName = "desktop";
      site.connections.enable = true;
      site.containers = {
        enable = true;
      };
      virtualisation.emptyDiskImages = [ 2048 ];
      virtualisation.fileSystems."/persist" = {
        device = "/dev/vdb";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
      };
      services.tailscale = {
        enable = true;
        useRoutingFeatures = "both";
        extraSetFlags = [
          "--advertise-exit-node=true"
          "--snat-subnet-routes=true"
        ];
      };
      systemd.services.tailscaled.environment.TS_DEBUG_DISCO = "true";
      users.users.desktop = {
        isNormalUser = true;
        uid = 1000;
      };
      # Keep the deliberate daemon crash observable until the test restores it.
      systemd.services.mullvad-daemon.serviceConfig.Restart = lib.mkForce "no";
      networking.interfaces.eth1 = {
        ipv4.addresses = lib.mkForce [ ];
        ipv6.addresses = lib.mkForce [ ];
      };
      networking.networkmanager = {
        unmanaged = [ "interface-name:eth0" ];
        ensureProfiles.profiles.underlay = {
          connection = {
            id = "underlay";
            uuid = "4279ef70-b90f-41e2-ae23-472c61e58a68";
            type = "ethernet";
            interface-name = "eth1";
          };
          ipv4 = {
            method = "manual";
            address1 = "192.168.1.10/24,192.168.1.20";
            route1 = "198.18.0.0/15,192.168.1.30";
          };
          ipv6 = {
            method = "manual";
            address1 = "2001:db8:10::10/64,2001:db8:10::20";
            route1 = "2001:db8:1::/64,2001:db8:10::30";
            route2 = "2001:db8:2::/64,2001:db8:10::30";
          };
        };
      };
      site.network = {
        dns.enable = true;
        singBox.enable = true;
        lockdown.enable = true;
        providerFile = "/run/provider.json";
        runtimeRouteDirectory = "/var/lib/network-policy/route.d";
        runtimeConnectionDirectory = "/var/lib/network-policy/connection.d";
        directNetworks = [
          "198.18.0.30/32"
          "2001:db8:1::30/128"
        ];
        blockedNetworks = [ "198.19.0.31/32" ];
        dnsPolicy = {
          caStore = "${certificates.ca.cert}";
          groups = {
            cn.upstreams = upstreams 24001;
            global.upstreams = upstreams 24003;
          };
        };
        routeFragments = {
          "20-private.json".rules = [
            {
              domain_suffix = [
                "home.arpa"
                "lan"
                "ts.net"
              ];
              outbound = "private";
            }
          ];
          "40-fixture.json".rules = [
            {
              domain = "special.example.test";
              outbound = "proxy";
            }
            {
              domain = "api.other.test";
              outbound = "direct";
            }
            {
              domain_suffix = [
                "direct.test"
                "example.test"
              ];
              outbound = "direct";
            }
            {
              domain_suffix = "blocked.test";
              action = "reject";
            }
          ];
        };
      };
      systemd.services.continuous = {
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        before = [
          "network-pre.target"
          "sysinit.target"
        ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          User = "desktop";
          ExecStart = "${fixture} continuous";
          Restart = "always";
        };
      };
    };
    upstream = {
      virtualisation.vlans = [
        1
        2
      ];
      networking.firewall.enable = false;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      # The peer underlay is an IPv4 NAT segment. Tailnet carries both families.
      networking.interfaces.eth2 = {
        ipv4.addresses = lib.mkForce [
          {
            address = "192.168.2.20";
            prefixLength = 24;
          }
        ];
        ipv6.addresses = lib.mkForce [ ];
      };
      networking.nftables = {
        enable = true;
        tables.peer-nat = {
          family = "ip";
          content = ''
            chain forward {
              type filter hook forward priority 0; policy accept;
              ct state established,related accept
              iifname "eth1" oifname "eth2" drop
            }
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr 192.168.2.0/24 oifname "eth1" masquerade
            }
          '';
        };
      };
      networking.interfaces.eth1 = {
        ipv4.addresses = lib.mkForce [
          {
            address = "192.168.1.20";
            prefixLength = 24;
          }
        ];
        ipv4.routes = [
          {
            address = "198.18.0.0";
            prefixLength = 15;
            via = "192.168.1.30";
          }
        ];
        ipv6.addresses = lib.mkForce [
          {
            address = "2001:db8:10::20";
            prefixLength = 64;
          }
        ];
        ipv6.routes =
          map
            (address: {
              inherit address;
              prefixLength = 64;
              via = "2001:db8:10::30";
            })
            [
              "2001:db8:1::"
              "2001:db8:2::"
            ];
      };
      systemd.services.dns-fixture = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${fixture} dns --cert ${cert} --key ${key}";
      };
      systemd.services.proxy = {
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "dns-fixture.service"
        ];
        preStart = ''
          if ! test -e /run/proxy.json; then cp ${hyConfig} /run/proxy.json; fi
        '';
        serviceConfig.ExecStart = "${pkgs.sing-box}/bin/sing-box run -c /run/proxy.json";
      };
    };
    peer = {
      virtualisation.vlans = [ 2 ];
      networking.firewall.allowedTCPPorts = [ 18083 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.2.50";
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      networking.defaultGateway = "192.168.2.20";
      services.tailscale = {
        enable = true;
        openFirewall = true;
        useRoutingFeatures = "client";
      };
      systemd.services.tailscaled.environment.TS_DEBUG_DISCO = "true";
      systemd.services.tailnet-http = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${python}/bin/python3 -m http.server 18083 --bind :: --directory ${pkgs.writeTextDir "tailnet.txt" "tailnet peer"}";
      };
    };
    target = {
      imports = [ notification.server ];
      systemd.services.notification-fixture.serviceConfig.ExecStart =
        notification.command + " --address 198.19.0.30";
      networking.firewall.enable = false;
      # STUN observes the peer after SNAT, on a server outside its router.
      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale.test.nix";
          derp = {
            urls = [ ];
            server = {
              enabled = true;
              region_id = 999;
              region_code = "fixture";
              ipv4 = "192.168.1.30";
              stun_listen_addr = "0.0.0.0:3478";
            };
          };
          dns = {
            base_domain = "fixture.ts.net";
            override_local_dns = false;
          };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts."headscale.test.nix" = {
          onlySSL = true;
          listenAddresses = [ "192.168.1.30" ];
          sslCertificate = cert;
          sslCertificateKey = key;
          locations."/" = {
            proxyPass = "http://127.0.0.1:8080";
            proxyWebsockets = true;
          };
        };
      };
      environment.systemPackages = [ pkgs.headscale ];
      networking.interfaces.eth1 = {
        ipv4.addresses = lib.mkForce (
          map
            (address: {
              inherit address;
              prefixLength = if address == "192.168.1.30" then 24 else 32;
            })
            [
              "192.168.1.30"
              "198.18.0.30"
              "198.19.0.30"
              "198.19.0.31"
            ]
        );
        ipv6.addresses = lib.mkForce (
          map
            (address: {
              inherit address;
              prefixLength = 64;
            })
            [
              "2001:db8:10::30"
              "2001:db8:1::30"
              "2001:db8:2::30"
            ]
        );
      };
      systemd.services.observer = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${fixture} target";
      };
    };
  };
  testScript = ''
    from collections import Counter
    import json
    import shlex

    exit_active = False

    def ready_underlay():
        client.wait_until_succeeds("python3 -c 'import json; assert json.load(open(\"/run/site-network-underlay/underlay.json\"))[\"interface\"] == \"eth1\"'", timeout=90)

    # Observe the first cold boot as well as later shutdown/crash recovery.
    target.start()
    upstream.start()
    target.wait_for_unit("observer.service")
    target.wait_for_open_port(18082, addr="2001:db8:2::30")
    upstream.wait_for_unit("proxy.service")
    upstream.wait_for_open_port(24001)
    target.wait_for_unit("headscale.service")
    target.wait_for_open_port(443, addr="192.168.1.30")
    peer.start()
    peer.wait_for_unit("tailscaled.service")
    client.start()
    client.wait_for_unit("site-network-routing.service")
    # The underlay watcher stops the proxy while replacing its first binding.
    # Installed capture routes do not mean that transition has finished.
    ready_underlay()
    provider = {"outbounds": [{"type": "hysteria2", "tag": "synthetic", "server": "192.168.1.20", "server_port": 4443,
      "password": "public-test-fixture-only", "tls": {"enabled": True, "server_name": "dns.test.nix", "certificate_path": "${certificates.ca.cert}"}}]}
    provider_text = shlex.quote("// synthetic nodes\n" + json.dumps(provider))
    client.succeed("install -m600 /dev/null /run/provider.json; echo " + provider_text + " > /run/provider.json")
    client.succeed("network-policy apply")
    client.wait_until_succeeds("test $(systemctl show site-network-connect -p Result --value) = success")
    client.succeed("test $(stat -c %a /run/sing-box/config.json) = 600")
    client.fail("su -s /bin/sh desktop -c 'network-lockdown disconnect'")

    def user(command, fail=False):
        return (client.fail if fail else client.succeed)("su -s /bin/sh desktop -c " + shlex.quote(command))

    def http(host, fail=False):
        return user("curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/check", fail)

    def healthy():
        paths = (("198.18.0.30", "192.168.1.10"), ("198.19.0.30", "192.168.1.20"),
                 ("[2001:db8:1::30]", "2001:db8:10::10"), ("[2001:db8:2::30]", "2001:db8:10::20"))
        # IPv4 being ready does not establish IPv6 readiness after link-up/DAD.
        # Retry the complete egress contract; every successful path must still
        # use its exact expected source, including during recovery.
        probes = ["observed=$(curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/health); "
                  + 'test "$observed" = ' + shlex.quote(source) for host, source in paths]
        try:
            client.wait_until_succeeds("su -s /bin/sh desktop -c " + shlex.quote("set -eu; " + "; ".join(probes)), timeout=90)
        except Exception:
            for command in ("ip -4 rule show", "ip -6 rule show", "ip -4 route show table all",
                            "ip -6 route show table all", "ip -j address show dev eth1", "nft list ruleset",
                            "journalctl -u sing-box -u site-network-underlay -n 80 --no-pager"):
                print(command, client.execute(command)[1])
            raise
        client.succeed("ip -4 route get 198.19.0.30 | grep 'dev wg0-mullvad'")
        client.succeed("ip -6 route get 2001:db8:2::30 | grep 'dev wg0-mullvad'")
        if exit_active:
            peer.wait_until_succeeds("set -eu; " + "; ".join(probes), timeout=90)

    def blocked():
        for host in ("198.18.0.30", "198.19.0.30", "[2001:db8:1::30]", "[2001:db8:2::30]"):
            http(host, True)
            if exit_active:
                peer.fail("curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/exit-blocked")

    healthy()
    client.wait_for_unit("docker-site-apprise.service")
    client.wait_for_unit("docker-site-bark.service")
    client.wait_until_succeeds("su -s /bin/sh sender -c 'bark 分流出口通知'", timeout=180)
    notification_events = [json.loads(line) for line in target.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
    assert notification_events[-1]["peer"] == "192.168.1.20", notification_events
    # Real control, STUN, NAT traversal and relay traffic share this fixture.
    # The peer is behind the upstream's NAT, with unsolicited inbound blocked.
    for machine in (client, peer, upstream):
        machine.succeed("systemd-run --unit=tailnet-packets tcpdump -U -ni any -w /run/tailnet.pcap 'udp port 41641 or udp port 3478'")
    client.succeed("nft add table inet tailnet_trace; nft 'add chain inet tailnet_trace input { type filter hook prerouting priority -301; policy accept; }'; nft add rule inet tailnet_trace input udp dport 41641 meta nftrace set 1")
    client.succeed("systemd-run --unit=tailnet-trace sh -c '${pkgs.nftables}/bin/nft monitor trace > /run/tailnet-trace.log'")
    target.succeed("headscale users create fixture")
    authkey = target.succeed("headscale preauthkeys -u 1 create --reusable").strip()
    login = "tailscale up --accept-dns=false --login-server https://headscale.test.nix --auth-key " + shlex.quote(authkey)
    client.wait_for_unit("tailscaled.service")
    client.succeed(login + " --advertise-exit-node --snat-subnet-routes=true")
    peer.succeed(login)
    peer4 = peer.succeed("tailscale ip -4").strip()
    peer6 = peer.succeed("tailscale ip -6").strip()
    direct_ping = "tailscale ping --c 10 --until-direct=true " + peer4 + " | grep -E 'via [0-9.]+:[0-9]+'"
    def direct_ready():
        try:
            client.wait_until_succeeds(direct_ping, timeout=90)
        except Exception:
            for machine in (client, peer, upstream):
                for command in ("tailscale status --json", "ip -4 rule show", "ip -4 route show table all",
                                "nft list ruleset", "journalctl -u tailscaled -n 200 --no-pager",
                                "ss -uapn",
                                "tcpdump -nn -r /run/tailnet.pcap -c 160"):
                    print(machine.name, command, machine.execute(command)[1])
            print(client.execute("tail -n 240 /run/tailnet-trace.log")[1])
            raise
    direct_ready()
    client.succeed("ip -4 route get " + peer4 + " | grep 'dev tailscale0'")
    client.succeed("ip -6 route get " + peer6 + " | grep 'dev tailscale0'")

    def tailnet():
        for host in (peer4, "[" + peer6 + "]"):
            assert user("curl --noproxy '*' --max-time 8 -sSf http://" + host + ":18083/tailnet.txt").strip() == "tailnet peer"

    tailnet()
    check = json.loads(client.succeed("mullvad-exclude tailscale netcheck --format=json"))
    assert check["UDP"] and check["PreferredDERP"] == 999, check
    user("dig +short controlplane.tailscale.com A | grep -Fx 198.18.0.30")
    user("dig +short peer.fixture.ts.net A | grep -Fx " + peer4)
    target.succeed("grep '192.168.1.10 .*GET /key' /var/log/nginx/access.log")
    # A real Tailnet client selects this host as its dual-stack Internet exit.
    # Observe both clients at the destination through every later lifecycle event.
    client4 = client.succeed("tailscale ip -4").strip()
    nodes = json.loads(target.succeed("headscale nodes list --output json"))
    exit_id = next(node["id"] for node in nodes if client4 in node["ip_addresses"])
    target.succeed(f"headscale nodes approve-routes --identifier {exit_id} --routes 0.0.0.0/0,::/0")
    peer.wait_until_succeeds("tailscale set --accept-dns=true --exit-node=" + client4, timeout=60)
    exit_active = True
    healthy()
    peer.succeed("systemd-run --unit=exit-continuous ${fixture} continuous --origin exit")

    def exit_dns():
        # Quad100 forwards public queries over the exit node's PeerAPI to its
        # system resolver. Verify the returned policy and actual DNS journal.
        for transport in ("", "+tcp"):
            for name, expected in (("exit.direct.test", "198.18.0.30"),
                                   ("exit.proxy.test", "198.19.0.30")):
                peer.succeed(f"dig {transport} +time=3 +tries=1 +short {name} A | grep -Fx {expected}")
        peer.succeed("dig +time=3 +tries=1 exit.blocked.test | grep NXDOMAIN")
        peer.succeed("dig +short client.fixture.ts.net A | grep -Fx " + client4)
        client.wait_until_succeeds("journalctl -u site-dns-events -o cat --no-pager | network-dns-log --name exit.direct.test | grep '40-fixture.json/rules/2'")
        for name, source in (("exit.direct.test", "192.168.1.10"), ("exit.proxy.test", "192.168.1.20")):
            assert peer.succeed(f"curl -4 --noproxy '*' --max-time 8 -sSf http://{name}:18080/exit-domain").strip() == source

    exit_dns()
    def ipv4_healthy():
        client.succeed("network-ipv6 status")
        for machine in (client, peer):
            for host, source in (("198.18.0.30", "192.168.1.10"), ("198.19.0.30", "192.168.1.20")):
                machine.wait_until_succeeds("test $(curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/ipv4-mode) = " + source, timeout=60)
            # Exit-node routes can recover before the peer receives its updated
            # PeerAPI DNS endpoint from the control plane.
            machine.wait_until_succeeds("dig +time=3 +tries=1 web.proxy.test AAAA | grep 'status: NOERROR' && dig +time=3 +tries=1 +short web.proxy.test A | grep -Fx 198.19.0.30", timeout=60)
            assert machine.succeed("dig +short web.proxy.test AAAA").strip() == ""
            machine.fail("curl --noproxy '*' --max-time 4 -sSf 'http://[2001:db8:2::30]:18080/ipv4-mode'")
        direct_ready()
        assert user("curl --noproxy '*' --max-time 8 -sSf http://" + peer4 + ":18083/tailnet.txt").strip() == "tailnet peer"
        exit_dns()

    client.succeed("network-ipv6 off")
    ipv4_healthy()
    client.succeed("network-policy apply; systemctl reload nftables; systemctl restart site-dns sing-box site-network-connect")
    client.wait_until_succeeds("network-ipv6 status", timeout=60)
    ipv4_healthy()
    client.succeed("nmcli connection down underlay; nmcli connection up underlay")
    client.wait_until_succeeds("network-ipv6 status", timeout=90)
    ipv4_healthy()
    client.succeed("network-ipv6 restore")
    healthy()
    user("dig +short web.proxy.test AAAA | grep -Fx 2001:db8:2::30")
    client.succeed("systemctl restart docker")
    healthy()
    client.wait_until_succeeds("su -s /bin/sh sender -c 'bark 容器服务恢复'", timeout=90)
    # Force relay fallback by dropping only peer UDP, keeping control/STUN alive.
    client.succeed("nft add table inet relay_fixture; nft 'add chain inet relay_fixture output { type filter hook output priority -190; policy accept; }'; nft add rule inet relay_fixture output udp dport 41641 drop")
    peer.succeed("nft add table inet relay_fixture; nft 'add chain inet relay_fixture output { type filter hook output priority -190; policy accept; }'; nft add rule inet relay_fixture output udp dport 41641 drop")
    client.wait_until_succeeds("tailscale ping --c 1 --until-direct=false " + peer4 + " | grep 'DERP(fixture)'", timeout=60)
    tailnet()
    healthy()
    exit_dns()
    client.succeed("nft delete table inet relay_fixture")
    peer.succeed("nft delete table inet relay_fixture")
    direct_ready()
    tailnet()
    client.succeed("network-policy check")
    generation = client.succeed("readlink /run/site-network-policy/current")
    client.succeed("install -d -m700 /var/lib/network-policy/route.d; printf '%s' '{\"rules\":[{\"rule_set\":\"missing\",\"outbound\":\"direct\"}]}' > /var/lib/network-policy/route.d/05-local.json")
    client.fail("network-policy apply")
    assert generation == client.succeed("readlink /run/site-network-policy/current")
    healthy()
    override = {"rules": [{"domain": ["live.policy.example", "private.home.arpa"], "outbound": "direct"}]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(override)) + " > /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    healthy()
    user("dig +short live.policy.example A | grep -Fx 198.18.0.30")
    assert http("live.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
    user("dig +short private.home.arpa A | grep -Fx 198.18.0.30")
    dns_pid = client.succeed("systemctl show site-dns -p MainPID --value")
    connection = '// independent TCP routing\n{"rules":[{"domain":"live.policy.example","port":18080,"network":"tcp","outbound":"synthetic"},],}'
    client.succeed("install -d -m700 /var/lib/network-policy/connection.d; printf '%s' " + shlex.quote(connection) + " > /var/lib/network-policy/connection.d/03-work.jsonc; network-policy apply")
    healthy()
    user("dig +short live.policy.example A | grep -Fx 198.18.0.30")
    assert http("live.policy.example") in {"192.168.1.20", "2001:db8:10::20"}
    assert client.succeed("systemctl show site-dns -p MainPID --value") == dns_pid
    client.succeed("mv /var/lib/network-policy/connection.d/03-work.jsonc /var/lib/network-policy/connection.d/60-work.jsonc; network-policy apply")
    healthy()
    assert http("live.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
    client.succeed("rm /var/lib/network-policy/connection.d/60-work.jsonc; network-policy apply")
    override = {"rules": [{"domain": "live.policy.example", "action": "reject"}]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(override)) + " > /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    healthy()
    user("dig live.policy.example | grep NXDOMAIN")
    client.succeed("rm /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    healthy()
    for name, expected in (("direct.test", "198.18.0.30"), ("special.example.test", "198.19.0.30"),
                           ("api.other.test", "198.18.0.30"), ("apixother.test", "198.19.0.30")):
        for transport in ("", "+tcp"):
            user(f"dig {transport} +short {name} A | grep -Fx {expected}")
    user("dig private.home.arpa | grep NXDOMAIN")
    user("dig blocked.test | grep NXDOMAIN")
    # Hostnames have both A and AAAA answers; a proxy may resolve remotely and
    # choose a different address family. The egress host is the invariant here;
    # healthy() checks each literal IPv4/IPv6 path separately above.
    for hostname, sources in (("web.direct.test", {"192.168.1.10", "2001:db8:10::10"}),
                              ("web.proxy.test", {"192.168.1.20", "2001:db8:10::20"})):
        observed = http(hostname)
        print(json.dumps({"hostname": hostname, "observed_source": observed}))
        assert observed in sources, (hostname, observed, sources)
    http("blocked.test", True)
    # Journals and file rotation remain live while the egress observer runs.
    client.wait_until_succeeds("journalctl -u site-dns-events -o cat --no-pager | network-dns-log --name direct.test | grep '40-fixture.json/rules/2'")
    client.wait_until_succeeds("journalctl -u site-dns-race-cn -o cat --no-pager | grep direct.test")
    client.succeed("python3 -c 'import dns.message,dns.query; from pathlib import Path; r=dns.query.tcp(dns.message.make_query(\"large.direct.test\",\"TXT\"),\"127.0.0.1\",port=5300); assert r.answer[0][0].strings==(b\"x\"*200,)*200; Path(\"/run/large-answer.wire\").write_bytes(r.to_wire(max_size=65535))'")
    client.wait_until_succeeds("journalctl -u site-dns-events -o cat --no-pager | network-dns-log --name large.direct.test > /run/large-events.jsonl; python3 -c 'import json,dns.message; from pathlib import Path; expected=dns.message.from_wire(Path(\"/run/large-answer.wire\").read_bytes()).answer; events=[json.loads(line) for line in Path(\"/run/large-events.jsonl\").read_text().splitlines()]; assert any(e[\"identity\"]==\"dnsdist-client\" and dns.message.from_text(e[\"dns\"]).answer==expected for e in events)'")
    client.succeed("journalctl -u sing-box -o cat --no-pager | grep DEBUG")
    client.succeed("journalctl -u mullvad-daemon -o cat --no-pager | grep DEBUG")
    pids = client.succeed("systemctl show mullvad-daemon sing-box site-dns -p MainPID")
    client.succeed("python3 -c 'from pathlib import Path; p=Path(\"/var/log/mullvad-vpn/daemon.log\"); p.open(\"a\").write(\"rotation-fixture\\n\" * 1200000)'")
    client.succeed("systemctl start site-network-logrotate; gzip -t /var/log/mullvad-vpn/daemon.log.1.gz")
    healthy()
    assert pids == client.succeed("systemctl show mullvad-daemon sing-box site-dns -p MainPID")
    client.succeed("journalctl --sync; journalctl --rotate")
    user("dig +short after-rotation.direct.test A | grep -Fx 198.18.0.30")
    client.wait_until_succeeds("journalctl -u site-dns-events -o cat --no-pager | network-dns-log --name after-rotation.direct.test | grep 198.18.0.30")
    upstream.fail("nc -z -w2 192.168.1.10 10800")
    upstream.fail("nc -z -w2 192.168.1.10 5300")
    # A single unbound UDP socket changes destinations without retaining its old policy.
    code = "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4); "
    code += "s.sendto(b'direct-udp',('198.18.0.30',18081)); assert s.recv(100)==b'192.168.1.10'; "
    code += "s.sendto(b'proxy-udp',('198.19.0.30',18081)); assert s.recv(100)==b'192.168.1.20'"
    user("python3 -c " + shlex.quote(code))
    user("ping -c1 -W2 198.19.0.30", True)
    user("ping -6 -c1 -W2 2001:db8:2::30", True)
    client.succeed("systemctl reload nftables")
    healthy()
    upstream.succeed("systemctl stop proxy")
    tailnet()
    http("198.19.0.30", True)
    assert http("198.18.0.30") == "192.168.1.10"
    peer.fail("curl --noproxy '*' --max-time 6 -sSf http://198.19.0.30:18080/exit-proxy-loss")
    assert peer.succeed("curl --noproxy '*' --max-time 6 -sSf http://198.18.0.30:18080/exit-direct").strip() == "192.168.1.10"
    upstream.succeed("systemctl start proxy")
    healthy()
    for unit in ("sing-box", "site-network-routing", "mullvad-daemon"):
        client.succeed("systemctl stop " + unit)
        tailnet()
        blocked()
        # These requests overlap the watcher during reconnection. Readiness is
        # established by actual dual-stack egress below, not a systemd job race.
        client.succeed("systemctl --no-block start " + unit)
        client.succeed("systemctl --no-block restart site-network-connect sing-box")
        healthy()
    client.succeed("network-lockdown disconnect")
    blocked()
    client.succeed("network-lockdown connect")
    healthy()
    # Separate abrupt daemon loss from tunnel loss. A graceful service stop
    # cannot establish either of these failure boundaries.
    client.succeed("systemctl kill -s SIGKILL --kill-whom=main mullvad-daemon")
    status, observed = client.execute("su -s /bin/sh desktop -c " + shlex.quote("curl --noproxy '*' --max-time 6 -sSf http://198.19.0.30:18080/daemon-loss"))
    assert status != 0 or observed == "192.168.1.20"
    client.succeed("ip link delete wg0-mullvad || test ! -e /sys/class/net/wg0-mullvad")
    tailnet()
    blocked()
    client.succeed("systemctl restart mullvad-daemon site-network-connect")
    healthy()
    client.succeed("echo '{\"outbounds\":[]}' > /run/provider.json")
    client.fail("network-policy apply")
    healthy()
    # Explicit interface use reaches the remote VPN without changing ordinary
    # direct/proxy routing. These credentials belong only to this synthetic lab.
    client_key = client.succeed("wg genkey").strip()
    server_key = upstream.succeed("wg genkey").strip()
    client_public = client.succeed("printf '%s' " + shlex.quote(client_key) + " | wg pubkey").strip()
    server_public = upstream.succeed("printf '%s' " + shlex.quote(server_key) + " | wg pubkey").strip()
    remote = json.loads(upstream.succeed("cat /run/proxy.json"))
    remote["endpoints"] = [
      {"type": "wireguard", "tag": "test-wg", "address": ["10.88.0.1/24"], "listen_port": 51830,
       "private_key": server_key, "peers": [{"public_key": client_public, "allowed_ips": ["10.88.0.2/32"]}]},
      {"type": "openvpn-server", "tag": "test-ovpn", "listen": "0.0.0.0", "listen_port": 1194,
       "address": ["10.89.0.1/24"], "users": [{"username": "synthetic", "password": "synthetic"}],
       "tls": {"certificate_path": "${cert}", "key_path": "${key}", "verify_client_certificate": "none"}}]
    upstream.succeed("printf '%s' " + shlex.quote(json.dumps(remote)) + " > /run/proxy.json; systemctl restart proxy")
    provider["endpoints"] = [
      {"type": "wireguard", "tag": "private-wg", "system": True, "name": "foo", "address": ["10.88.0.2/32"],
       "private_key": client_key, "peers": [{"address": "192.168.1.20", "port": 51830,
                                            "public_key": server_public, "allowed_ips": ["0.0.0.0/0"]}]},
      {"type": "openvpn-client", "tag": "private-ovpn", "system": True, "name": "bar",
       "server": "192.168.1.20", "server_port": 1194, "username": "synthetic", "password": "synthetic",
       "routes": ["0.0.0.0/0"], "tls": {"server_name": "*.test.nix", "certificate_path": "${certificates.ca.cert}"}}]
    client.succeed("printf '%s' " + shlex.quote(json.dumps(provider)) + " > /run/provider.json; network-policy apply")
    for interface in ("foo", "bar"):
        client.wait_until_succeeds(
          "mullvad-exclude setpriv --reuid=desktop --regid=users --init-groups curl --noproxy '*' --interface "
          + interface + " --max-time 5 -fsS http://198.18.0.30:18080/interface | grep -Fx 192.168.1.20", timeout=60)
    healthy()
    dns_pids = client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
    provider["outbounds"][0]["tag"] = "second-node"
    provider_text = shlex.quote("// synthetic nodes\n" + json.dumps(provider))
    client.succeed("echo " + provider_text + " > /run/provider.json; network-policy apply")
    assert dns_pids == client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
    healthy()
    generation = client.succeed("readlink /run/site-network-policy/current")
    credential = client.succeed("sha256sum /run/site-network-policy/current/provider.json")
    provider["outbounds"][0]["tag"] = "rollback-candidate"
    provider["endpoints"][0]["name"] = "lo"
    client.succeed("echo " + shlex.quote(json.dumps(provider)) + " > /run/provider.json")
    client.succeed("network-policy check")
    activation_failure = client.fail("network-policy apply 2>&1")
    assert "sing-box.service" in activation_failure, activation_failure
    diagnostic = json.loads(client.succeed("cat /run/site-network-policy/last-error.json"))
    assert diagnostic["phase"] == "policy activation" and "sing-box.service" in diagnostic["summary"], diagnostic
    assert generation == client.succeed("readlink /run/site-network-policy/current")
    assert credential == client.succeed("sha256sum /run/site-network-policy/current/provider.json")
    assert dns_pids == client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
    healthy()
    # The same endpoint fails after IPv6 shutdown has begun. Keep the packet
    # guard in place until a valid configuration completes a new transition.
    client.fail("network-ipv6 off")
    failed_status = client.fail("network-ipv6 status")
    assert "Failed step: activating DNS and proxy configuration" in failed_status, failed_status
    assert "sing-box.service" in failed_status, failed_status
    client.copy_from_machine("/run/site-network-policy/last-error.log", "ipv6-failure.log")
    peer.fail("curl --noproxy '*' --max-time 4 -sSf 'http://[2001:db8:2::30]:18080/family-failure'")
    provider["endpoints"][0]["name"] = "foo"
    client.succeed("echo " + provider_text + " > /run/provider.json; network-ipv6 off")
    ipv4_healthy()
    client.succeed("network-ipv6 restore")
    healthy()
    client.succeed("nmcli connection down underlay")
    blocked()
    client.wait_until_succeeds("python3 -c 'import json; state=json.load(open(\"/run/site-network-underlay/underlay.json\")); assert state is None or state[\"interface\"] != \"eth1\"'", timeout=30)
    client.succeed("nmcli connection up underlay")
    ready_underlay()
    healthy()
    persistent = {"rules": [{"domain": "persisted.policy.example", "outbound": "direct"}]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(persistent)) + " > /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    client.succeed("journalctl --sync")
    # The observer remains running through both orderly and abrupt power loss.
    for shutdown in (client.shutdown, client.crash):
        client.succeed("network-ipv6 off")
        ipv4_healthy()
        shutdown()
        client.start()
        client.wait_for_unit("multi-user.target")
        client.succeed("journalctl -u site-dns-events -o cat --no-pager | network-dns-log --name after-rotation.direct.test | grep 198.18.0.30")
        client.succeed("test -s /var/log/mullvad-vpn/daemon.log.1.gz")
        blocked()  # runtime provider deliberately absent; no permissive startup.
        client.wait_for_unit("tailscaled.service")
        client.wait_until_succeeds(direct_ping, timeout=90)
        tailnet()
        ready_underlay()
        client.succeed("install -m600 /dev/null /run/provider.json; echo " + provider_text + " > /run/provider.json; network-policy apply")
        healthy()
        client.succeed("network-ipv6 status")
        user("dig +short persisted.policy.example A | grep -Fx 198.18.0.30")
        assert http("persisted.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
        peer.succeed("dig +short persisted.policy.example A | grep -Fx 198.18.0.30")
        exit_dns()
    client.succeed("systemctl stop continuous")
    peer.succeed("systemctl stop exit-continuous")
    observations = [json.loads(line) for line in target.succeed("cat /run/observations.jsonl").splitlines()]
    continuous = [row for row in observations if row["data"].startswith("/continuous/")]
    expected = {("direct", "4"): "192.168.1.10", ("direct", "6"): "2001:db8:10::10",
                ("proxy", "4"): "192.168.1.20", ("proxy", "6"): "2001:db8:10::20"}
    flows = Counter()
    connections = Counter()
    for row in continuous:
        _, _, policy, family, protocol, instance, connection, sequence = row["data"].strip().split("/")
        assert row["peer"] == expected[policy, family], "continuous traffic used an unexpected egress source: " + str(row)
        origin = instance.split("-", 1)[0]
        flows[origin, policy, family, protocol] += 1
        connections[origin, policy, family, protocol, instance, connection] += 1
    assert len(flows) == 16 and min(flows.values()) >= 10, str(flows)
    for flow in flows:
        assert any(key[:4] == flow and count >= 2 for key, count in connections.items()), "no reused socket for " + str(flow)
    print(json.dumps({"continuous_remote_observations": len(continuous), "flows": {"/".join(k): v for k, v in flows.items()}, "unexpected_sources": 0}))
    # The smaller capability combinations use fresh hosts; run them in sequence
    # after the continuous exit-node observation to keep peak VM memory bounded.
    client.shutdown()
    peer.shutdown()
    for node, address in ((dnsOnly, "192.168.1.11"), (dnsProxy, "192.168.1.12")):
        node.start()
        node.wait_for_unit("multi-user.target")
        node.wait_for_unit("site-dns.service")
        node.wait_until_succeeds("su -s /bin/sh sender -c 'bark 独立网络能力通知'", timeout=180)
        deliveries = [json.loads(line) for line in target.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
        assert deliveries[-1]["peer"] == address, deliveries[-1]
        node.succeed("network-ipv6 off; network-policy apply; systemctl restart site-dns")
        node.succeed("network-ipv6 status")
        assert node.succeed("dig +short www.example.org AAAA").strip() == ""
        node.succeed("su -s /bin/sh sender -c 'bark IPv4网络通知'")
        if node == dnsProxy:
            node.succeed("curl --proxy socks5h://127.0.0.1:10800 --max-time 8 -sSf http://www.example.org:18080/family")
        node.succeed("network-ipv6 restore")
        node.succeed("dig +short www.example.org AAAA | grep ':'")
        node.shutdown()
  '';
}
