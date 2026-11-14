{ inputs }:
{ pkgs, lib, ... }:
let
  notification = import ../fixtures/notifications.nix { inherit pkgs; };
  caches = import ../../nix/cache-config.nix;
  oranc = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.oranc;
  cachePayload = pkgs.writeText "network-cache-payload" "shared host cache content\n";
  initialRules = pkgs.runCommand "initial-domain-rules.srs" { } ''
    ${pkgs.sing-box}/bin/sing-box rule-set compile ${
      pkgs.writeText "initial-domain-rules.json" (
        builtins.toJSON {
          version = 3;
          rules = [ { domain = "initial.policy.example"; } ];
        }
      )
    } -o $out
  '';
  cacheURI = "http://${caches.local.listen}/cache.test.nix:5000/synthetic/network-cache";
  kdeconnect = pkgs.kdePackages.kdeconnect-kde;
  discoveryNode = {
    environment.systemPackages = [ kdeconnect ];
    systemd.services.kdeconnect-fixture = {
      path = [ pkgs.dbus ];
      environment = {
        HOME = "/run/kdeconnect-fixture";
        XDG_RUNTIME_DIR = "/run/kdeconnect-fixture";
        QT_QPA_PLATFORM = "offscreen";
        QT_LOGGING_RULES = "kdeconnect.core.debug=true";
      };
      serviceConfig = {
        RuntimeDirectory = "kdeconnect-fixture";
        RuntimeDirectoryMode = "0700";
        ExecStart = "${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.writeShellScript "kdeconnect-fixture" ''
          printf '%s' "$DBUS_SESSION_BUS_ADDRESS" > /run/kdeconnect-fixture/bus-address
          exec ${kdeconnect}/bin/kdeconnectd
        ''}";
      };
    };
  };
  containerImage = pkgs.dockerTools.buildLayeredImage {
    name = "network-workflow";
    tag = "test";
    contents = [
      pkgs.busybox
      pkgs.curl
      pkgs.dig
      pkgs.netcat-openbsd
      pkgs.zstd
    ];
    extraCommands = ''
      mkdir -p www tmp
      printf 'container service\n' > www/index.html
    '';
    config.Cmd = [
      "sleep"
      "infinity"
    ];
  };
  compose = pkgs.writeText "network-compose.json" (
    builtins.toJSON {
      services = {
        app = {
          image = "network-workflow:test";
          init = true;
          restart = "unless-stopped";
        };
        web = {
          image = "network-workflow:test";
          init = true;
          command = [
            "httpd"
            "-f"
            "-p"
            "8080"
            "-h"
            "/www"
          ];
          restart = "unless-stopped";
          ports = [
            "18084:8080"
            "18085:8080"
          ];
        };
      };
      networks.default = {
        enable_ipv6 = true;
        ipam.config = [
          { subnet = "172.29.80.0/24"; }
          { subnet = "fd12:3456:789a::/64"; }
        ];
      };
    }
  );
  containerNode = {
    imports = [ ../../modules/services/cache.nix ];
    site.cache = caches.project // {
      enable = true;
    };
    systemd.services.oranc = {
      wants = [ "docker.service" ];
      after = [ "docker.service" ];
    };
    site.network.localAccess.enable = true;
    networking.firewall.allowedTCPPorts = [ 18085 ];
    networking.firewall.interfaces.eth1.allowedUDPPorts = [ 18081 ];
    systemd.services.host-observer = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${fixture} host";
    };
    virtualisation.docker.daemon.settings = {
      bip = "${caches.project.listenAddress}/16";
      ipv6 = true;
      fixed-cidr-v6 = "fd12:3456:789b::/64";
    };
  };
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
      ../../modules/network/connections.nix
      ../../modules/services/containers.nix
      ../../modules/services/notifications.nix
      notification.credentials
      containerNode
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
    site.connections.enable = true;
    networking.interfaces.eth1 = {
      ipv4.addresses = lib.mkForce [ ];
      ipv6.addresses = lib.mkForce [ ];
    };
    networking.networkmanager = {
      unmanaged = [ "interface-name:eth0" ];
      settings.main.no-auto-default = "eth1";
      ensureProfiles.profiles.underlay = {
        connection = {
          id = "underlay";
          uuid = "4279ef70-b90f-41e2-ae23-472c61e58a68";
          type = "ethernet";
          interface-name = "eth1";
        };
        ipv4 = {
          method = "manual";
          address1 = "${address}/24,192.168.1.20";
        };
        ipv6 = {
          method = "manual";
          address1 = "2001:db8:10::${lib.last (lib.splitString "." address)}/64,2001:db8:10::20";
        };
      };
    };
    environment.etc."test/provider.json".text = builtins.toJSON (
      {
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
      }
      // lib.optionalAttrs proxy {
        exits.fixture.paths = [ "synthetic" ];
        groups = lib.genAttrs [ "proxy" "hideme" ] (_: {
          exits = [ "fixture" ];
          default = "fixture";
        });
      }
    );
    site.network = {
      ipv6.enable = false;
      dns.enable = true;
      singBox.enable = proxy;
      purposeGroups = lib.optional proxy "hideme";
      providerFile = "/etc/test/provider.json";
      dnsPolicy = {
        caStore = "${certificates.ca.cert}";
        groups = {
          cn.upstreams = upstreams 24001;
          global.upstreams = upstreams 24003;
        }
        // lib.optionalAttrs proxy { hideme.upstreams = upstreams 24003; };
      };
      routeFragments = lib.optionalAttrs proxy {
        "40-purpose.json".rules = [
          {
            domain = "www.example.org";
            outbound = "hideme";
          }
        ];
      };
    };
  };

in
{
  name = "mullvad-lockdown-and-shared-dns";
  globalTimeout = 3600;
  qemu.forceAccel = true;
  node.specialArgs = { inherit inputs; };
  defaults = {
    imports = [ (import ./background.nix { scenario = "network"; }) ];
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    networking.useDHCP = false;
    networking.interfaces.eth0.useDHCP = lib.mkForce false;
    networking.extraHosts = "192.168.1.30 headscale.test.nix cache.test.nix";
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
      pkgs.zstd
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
        containerNode
        discoveryNode
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
          "--shields-up=false"
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
        # This link uses the declared static profile; the fixture has no DHCP server.
        settings.main.no-auto-default = "eth1";
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
            route1 = "192.0.2.0/24,192.168.1.30";
            route2 = "198.51.100.0/24,192.168.1.30";
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
        ipv6.enable = false;
        dns.enable = true;
        dns.fakeIP.excludeFile = "/var/lib/network-policy/fakeip-exclude.jsonc";
        singBox.enable = true;
        lockdown.enable = true;
        providerFile = "/run/provider.json";
        runtimeRouteDirectory = "/var/lib/network-policy/route.d";
        runtimeConnectionDirectory = "/var/lib/network-policy/connection.d";
        directNetworks = [
          "192.0.2.30/32"
          "2001:db8:1::30/128"
        ];
        blockedNetworks = [ "198.51.100.31/32" ];
        dnsPolicy = {
          caStore = "${certificates.ca.cert}";
          groups = {
            cn.upstreams = upstreams 24001;
            global.upstreams = upstreams 24003;
          };
        };
        routeFragments = {
          "35-remote.json" = {
            rule_set = [
              {
                type = "remote";
                tag = "downloaded-domains";
                format = "binary";
                url = "http://192.168.1.20:18089/domains.srs";
                initial_path = "${initialRules}";
              }
            ];
            rules = [
              {
                rule_set = "downloaded-domains";
                outbound = "direct";
              }
            ];
          };
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
      systemd.tmpfiles.rules = [
        "d /var/lib/network-policy 0700 root root -"
        "f /var/lib/network-policy/fakeip-exclude.jsonc 0600 root root - {}"
      ];
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
      systemd.services.rule-source = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          RuntimeDirectory = "rule-source";
          ExecStartPre = "${pkgs.coreutils}/bin/cp ${initialRules} /run/rule-source/domains.srs";
          ExecStart = "${python}/bin/python3 -m http.server 18089 --bind 0.0.0.0 --directory /run/rule-source";
        };
      };
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
        ipv4.routes =
          map
            (address: {
              inherit address;
              prefixLength = 24;
              via = "192.168.1.30";
            })
            [
              "192.0.2.0"
              "198.51.100.0"
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
      imports = [
        notification.server
        discoveryNode
      ];
      services.openssh.enable = true;
      services.openssh.settings.PasswordAuthentication = false;
      systemd.services.notification-fixture.serviceConfig.ExecStart =
        notification.command + " --address 198.51.100.30";
      networking.firewall.enable = false;
      nix.settings.experimental-features = [ "nix-command" ];
      virtualisation.additionalPaths = [ cachePayload ];
      services.dockerRegistry = {
        enable = true;
        listenAddress = "192.168.1.30";
        extraConfig.http.tls = {
          certificate = "${cert}";
          key = "${key}";
        };
      };
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
      environment.systemPackages = [
        pkgs.headscale
        oranc
      ];
      networking.interfaces.eth1 = {
        ipv4.addresses = lib.mkForce (
          map
            (address: {
              inherit address;
              prefixLength = if address == "192.168.1.30" then 24 else 32;
            })
            [
              "192.168.1.30"
              "192.0.2.30"
              "198.51.100.30"
              "198.51.100.31"
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
        serviceConfig.ExecStart = "${fixture} target --cert ${cert} --key ${key}";
      };
    };
  };
  testScript = ''
    from collections import Counter
    import ipaddress
    import json
    import shlex
    import time

    exit_active = False
    containers_active = False
    compose_command = "docker compose -p network-workflow -f ${compose}"
    compose_exec = compose_command + " exec -T --interactive=false app"

    def container_start(node):
        node.wait_for_unit("site-container-network.service")
        node.succeed("docker load -i ${containerImage}", timeout=120)
        node.succeed("docker run -d --init --restart unless-stopped --name ordinary network-workflow:test")
        node.succeed(compose_command + " up -d", timeout=60)

    def container_request(node, command):
        try:
            node.wait_until_succeeds("timeout -k 2 15 sh -c " + shlex.quote(command), timeout=60)
        except Exception:
            for diagnostic in ("journalctl -u site-container-network -u systemd-resolved -n 80 --no-pager",
                               "ip -4 rule show", "ip -6 rule show", "ip -4 route show table all",
                               "ip -6 route show table all", "ip -j address", "nft list ruleset",
                               "docker exec ordinary cat /etc/resolv.conf", "docker network ls",
                               compose_exec + " ip -6 route", compose_exec + " ip -6 neigh"):
                print(node.name, diagnostic, node.execute("timeout -k 2 10 sh -c " + shlex.quote(diagnostic))[1])
            raise

    def container_web(node, proxy_source, ipv6=False):
        names = ("web.direct.test", "web.proxy.test") if node == client else ("www.example.cn", "www.example.org")
        for command in ("docker exec ordinary", compose_exec):
            for name, source in zip(names, ("192.168.1.10" if node == client else proxy_source, proxy_source)):
                container_request(node, command + " sh -c " + shlex.quote(
                    "test $(curl -4 --noproxy '*' --max-time 6 -sSf http://" + name + ":18080/container) = " + source
                ))
        if ipv6:
            container_request(node, compose_exec + " sh -c " + shlex.quote(
                "test $(curl -6 --noproxy '*' --max-time 6 -sSf 'http://[2001:db8:2::30]:18080/container') = 2001:db8:10::20"
            ))

    def container_local(node, address="192.168.1.10"):
        container_request(node, compose_exec + " curl --max-time 6 -fsS http://web:8080 | grep -Fx 'container service'")
        for host in ("127.0.0.1", address):
            container_request(node, "curl --max-time 6 -fsS http://" + host + ":18084 | grep -Fx 'container service'")
        gateway = node.succeed("docker inspect ordinary --format '{{.NetworkSettings.Networks.bridge.Gateway}}'").strip()
        source = node.succeed("docker inspect ordinary --format '{{.NetworkSettings.Networks.bridge.IPAddress}}'").strip()
        container_request(node, f"docker exec ordinary curl --max-time 6 -fsS http://{gateway}:18080/host | grep -Fx {source}")
        container_request(node, f"printf host-access | docker exec -i ordinary nc -u -w 2 {gateway} 18081 | grep -Fx {source}")
        # A custom bridge has the same host-service contract as docker0.
        custom = node.succeed(compose_command + " ps -q app").strip()
        network = json.loads(node.succeed("docker inspect " + custom))[0]["NetworkSettings"]["Networks"]
        custom_network = next(iter(network.values()))
        for command, endpoint, expected in ((compose_exec, custom_network["Gateway"], custom_network["IPAddress"]),
                                             ("docker exec ordinary", address, source)):
            container_request(node, f"{command} curl --max-time 6 -fsS http://{endpoint}:18080/host | grep -Fx {expected}")
        # A wildcard UDP socket replies from the egress interface's address.
        # Use each bridge's gateway for connected UDP clients; TCP also covers
        # access through the host's physical-interface address above.
        container_request(node, compose_exec + " sh -c " + shlex.quote(
            f"printf host-access | nc -u -w 2 {custom_network['Gateway']} 18081 | grep -Fx {custom_network['IPAddress']}"
        ))
        name = "web.proxy.test" if node == client else "www.example.org"
        intercepted_dns(node, name, ["", "docker exec ordinary ", compose_exec + " "])
        shared_cache(node)

    def shared_cache(node):
        # Every client downloads real NAR bytes through the hardened host
        # service. A separate OCI integration verifies signature acceptance by
        # native Nix; this scenario exercises the network and service lifecycle.
        node.wait_for_unit("oranc.service")
        narinfo = node.succeed("curl --max-time 15 -fsS ${cacheURI}/${
          builtins.substring 0 32 (builtins.baseNameOf cachePayload)
        }.narinfo")
        fields = dict(line.split(": ", 1) for line in narinfo.splitlines() if ": " in line)
        assert fields["StorePath"] == "${cachePayload}" and fields["Sig"].startswith("network-cache-test:"), fields
        nar_url = "${cacheURI}/" + fields["URL"]
        for prefix in ("", "docker exec ordinary ", compose_exec + " "):
            command = "set -eu; curl --max-time 15 -fsS " + shlex.quote(nar_url) + " -o /tmp/cache-payload.nar.zst; "
            command += "zstd -dc /tmp/cache-payload.nar.zst | sha256sum | cut -d' ' -f1 | grep -Fx " + cache_nar_hash
            container_request(node, prefix + "sh -c " + shlex.quote(command))

    def intercepted_dns(node, name, prefixes, dual=False):
        expected = fake_address(node, name) if node in (client, peer) else "198.51.100.30"
        servers = ["203.0.113.53"] + (["2001:db8:ffff::53"] if dual else [])
        for prefix in prefixes:
            for server in servers:
                for transport in ("", "+tcp"):
                    container_request(node, f"{prefix}dig @{server} {transport} +time=3 +tries=1 +short {name} A | grep -Fx {expected}")

    def fake_address(node, name, kind="A", transport=""):
        address = node.succeed(f"dig {transport} +time=3 +tries=1 +short {name} {kind}").strip()
        pool = "198.18.0.0/15" if kind == "A" else "2001:2::/48"
        assert ipaddress.ip_address(address) in ipaddress.ip_network(pool), (name, address)
        return address

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
    target.wait_for_unit("docker-registry.service")
    target.succeed("umask 077; nix key generate-secret --key-name network-cache-test > /run/cache-signing-key")
    publisher = "oranc push --registry cache.test.nix:5000 --repository synthetic/network-cache --no-closure --parallel 1 --zstd-level 3"
    target.succeed('ORANC_SIGNING_KEY="$(cat /run/cache-signing-key)" ' + publisher + " initialize --priority 41")
    target.succeed("printf '%s\\n' '${cachePayload}' | ORANC_SIGNING_KEY=\"$(cat /run/cache-signing-key)\" " + publisher)
    cache_nar_hash = target.succeed("nix hash path --type sha256 --base16 ${cachePayload}").strip()
    # Exercise independent combinations first, with one client VM at a time.
    for node, address in ((dnsOnly, "192.168.1.11"), (dnsProxy, "192.168.1.12")):
        node.start()
        node.wait_for_unit("multi-user.target")
        node.wait_for_unit("site-dns.service")
        container_start(node)
        container_web(node, address)
        container_local(node, address)
        node.wait_until_succeeds("su -s /bin/sh sender -c 'bark 独立网络能力通知'", timeout=180)
        deliveries = [json.loads(line) for line in target.succeed("cat /run/notification-fixture/events.jsonl").splitlines()]
        assert deliveries[-1]["peer"] == address, deliveries[-1]
        node.succeed("network-ipv6 off; network-policy apply; systemctl restart site-dns")
        node.succeed("network-ipv6 status")
        container_web(node, address)
        assert node.succeed("dig +short www.example.org AAAA").strip() == ""
        node.succeed("su -s /bin/sh sender -c 'bark IPv4网络通知'")
        if node == dnsProxy:
            node.succeed("curl --proxy socks5h://127.0.0.1:10800 --max-time 8 -sSf http://www.example.org:18080/family")
            node.succeed("python3 -c 'import json; aliases=json.load(open(\"/run/site-network-policy/current/dns-groups.json\")); assert aliases[\"hideme\"] == aliases[\"global\"]'")
        node.succeed("network-ipv6 on")
        node.succeed("network-ipv6 status")
        node.succeed("dig +short www.example.org AAAA | grep ':'")
        intercepted_dns(node, "www.example.org", ["", "docker exec ordinary "], dual=True)
        node.shutdown()
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
    client.wait_until_succeeds("network-ipv6 status", timeout=60)
    assert client.succeed("dig +short web.proxy.test AAAA").strip() == ""
    client.succeed("curl --noproxy '*' --cacert ${certificates.ca.cert} --max-time 10 -fsS https://proxy.test.nix:18087/boot | grep -Fx 192.168.1.20")
    intercepted_dns(client, "web.proxy.test", [""])
    client.succeed("network-ipv6 on")

    def user(command, fail=False):
        return (client.fail if fail else client.succeed)("su -s /bin/sh desktop -c " + shlex.quote(command))

    def http(host, fail=False):
        return user("curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/check", fail)

    def opaque_egress(address, expected):
        # Neither protocol supplies a hostname. Only the address identifies
        # the domain, and the observer returns the actual egress source.
        code = "import socket,json; observed=[]\n"
        code += "for kind,port in ((socket.SOCK_STREAM,18082),(socket.SOCK_DGRAM,18081)):\n"
        family = "socket.AF_INET6" if ":" in address else "socket.AF_INET"
        code += f" with socket.socket({family},kind) as s:\n"
        code += f"  s.settimeout(5); s.connect(({address!r},port)); s.sendall(b'opaque payload\\n'); observed.append(s.recv(100).decode().strip())\n"
        code += "print(json.dumps(observed))"
        try:
            observed = json.loads(user("python3 -c " + shlex.quote(code)))
        except Exception:
            print(client.execute("journalctl --namespace=network -u sing-box -n 100 --no-pager")[1])
            print(client.execute("ip route get " + address if ":" not in address else "ip -6 route get " + address)[1])
            raise
        assert all(source in expected for source in observed), (address, expected, observed)

    def healthy():
        paths = (("192.0.2.30", "192.168.1.10"), ("198.51.100.30", "192.168.1.20"),
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
                            "journalctl --namespace=\"*\" -u sing-box -u site-network-underlay -n 80 --no-pager"):
                print(command, client.execute(command)[1])
            raise
        client.succeed("ip -4 route get 198.51.100.30 | grep 'dev wg0-mullvad'")
        client.succeed("ip -6 route get 2001:db8:2::30 | grep 'dev wg0-mullvad'")
        if exit_active:
            peer.wait_until_succeeds("set -eu; " + "; ".join(probes), timeout=90)
        if containers_active:
            container_web(client, "192.168.1.20", ipv6=True)

    def blocked():
        for host in ("192.0.2.30", "198.51.100.30", "[2001:db8:1::30]", "[2001:db8:2::30]"):
            http(host, True)
            if exit_active:
                peer.fail("curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/exit-blocked")
        if containers_active:
            for command in ("docker exec ordinary", compose_exec):
                client.fail(command + " curl --max-time 4 -sSf http://198.51.100.30:18080/container-blocked")

    healthy()
    container_start(client)
    containers_active = True
    container_web(client, "192.168.1.20", ipv6=True)
    container_local(client)
    def local_access():
        # Native private replies and opened public UDP replies must preserve
        # their source even when the server binds a wildcard socket.
        target.succeed("curl --noproxy '*' --max-time 6 -fsS http://192.168.1.10:18080/lan | grep -Fx 192.168.1.30")
        target.succeed("printf lan | nc -u -w 2 192.168.1.10 18081 | grep -Fx 192.168.1.30")
        target.succeed("printf public | nc -s 192.0.2.30 -u -w 2 192.168.1.10 18081 | grep -Fx 192.0.2.30")
        target.succeed("curl --noproxy '*' --max-time 6 -fsS http://192.168.1.10:18084 | grep -Fx 'container service'")
        target.succeed("curl --interface 192.0.2.30 --noproxy '*' --max-time 6 -fsS http://192.168.1.10:18085 | grep -Fx 'container service'")
        # Both published ports reach container 8080; only the declared host
        # port is public. The proxy listener is private as well.
        for port in (18080, 18084):
            target.fail(f"curl --interface 192.0.2.30 --noproxy '*' --max-time 2 -fsS http://192.168.1.10:{port}/public")
        target.fail("curl --interface 192.0.2.30 --proxy socks5h://192.168.1.10:10800 --max-time 2 -fsS http://web.proxy.test:18080/public")

    def explicit_proxy(machine, endpoint):
        for protocol in ("http", "socks5h"):
            machine.succeed(f"curl --proxy {protocol}://{endpoint}:10800 --max-time 8 -fsS http://web.proxy.test:18080/explicit | grep -Fx 192.168.1.20")

    local_access()
    # Real KDE Connect devices discover each other using LAN broadcast/mDNS,
    # then establish an authenticated connection without public port ranges.
    kde_bus = '$(cat /run/kdeconnect-fixture/bus-address)'
    def kde(machine, command, timeout=30):
        return machine.succeed('env DBUS_SESSION_BUS_ADDRESS="' + kde_bus + '" ' + command, timeout=timeout)

    def kde_reachable(machine, device):
        status, output = machine.execute(
            f'busctl --address="{kde_bus}" --timeout=2s get-property org.kde.kdeconnect '
            f'/modules/kdeconnect/devices/{device} org.kde.kdeconnect.device isReachable', timeout=5)
        return status == 0 and output.strip() == "b true"

    try:
        for machine in (client, target):
            machine.succeed("systemctl start kdeconnect-fixture.service")
            machine.wait_until_succeeds(
                'test -s /run/kdeconnect-fixture/bus-address && '
                'env DBUS_SESSION_BUS_ADDRESS="' + kde_bus + '" kdeconnect-cli --my-id | grep .', timeout=30)
            machine.wait_until_succeeds(
                "journalctl -b -u kdeconnect-fixture --no-pager -o cat | grep -Fx 'LanLinkProvider started'", timeout=30)
        client_device = kde(client, "kdeconnect-cli --my-id").strip()
        target_device = kde(target, "kdeconnect-cli --my-id").strip()
        peers = ((client, target_device), (target, client_device))
        discovery_started = time.monotonic()
        refreshes = 0
        while time.monotonic() - discovery_started < 45:
            reachable = [kde_reachable(machine, device) for machine, device in peers]
            if all(reachable):
                break
            elapsed = time.monotonic() - discovery_started
            if refreshes < 2 and elapsed >= 15 * (refreshes + 1):
                print(f"KDE Connect discovery refresh from client at {elapsed:.1f}s; reachable={reachable}")
                kde(client, "kdeconnect-cli --refresh", timeout=5)
                refreshes += 1
            time.sleep(1)
        else:
            raise AssertionError("KDE Connect peers did not become mutually reachable within 45 seconds")
        kde(client, "kdeconnect-cli --pair -d " + target_device)
        device_path = "/modules/kdeconnect/devices/" + client_device
        target.wait_until_succeeds(f'busctl --address="{kde_bus}" call org.kde.kdeconnect {device_path} org.kde.kdeconnect.device isPairRequestedByPeer | grep true', timeout=30)
        target.succeed(f'busctl --address="{kde_bus}" call org.kde.kdeconnect {device_path} org.kde.kdeconnect.device acceptPairing')
        for machine, device in ((client, target_device), (target, client_device)):
            machine.wait_until_succeeds('env DBUS_SESSION_BUS_ADDRESS="' + kde_bus + '" kdeconnect-cli -a --id-only | grep -Fx ' + device, timeout=30)
        # Send a file through the paired connection and observe the remote result.
        client.succeed("printf 'LAN discovery and transfer' > /run/kdeconnect-transfer.txt")
        kde(client, "kdeconnect-cli --share /run/kdeconnect-transfer.txt -d " + target_device)
        target.wait_until_succeeds("find /run/kdeconnect-fixture -name kdeconnect-transfer.txt -exec grep -lFx 'LAN discovery and transfer' {} + | grep .", timeout=30)
    except Exception as error:
        for machine in (client, target):
            for command in (f'busctl --address="{kde_bus}" tree org.kde.kdeconnect',
                            f'env DBUS_SESSION_BUS_ADDRESS="{kde_bus}" kdeconnect-cli -l',
                            "journalctl -u kdeconnect-fixture --no-pager -n 200"):
                try:
                    print(machine.name, command, machine.execute(command, timeout=10)[1])
                except Exception as diagnostic_error:
                    error.add_note(f"Collecting KDE Connect diagnostics on {machine.name}: {diagnostic_error}")
        raise
    explicit_proxy(client, "127.0.0.1")
    explicit_proxy(target, "192.168.1.10")
    container_request(client, "docker exec ordinary curl --proxy socks5h://172.17.0.1:10800 --max-time 8 -fsS http://web.proxy.test:18080/explicit | grep -Fx 192.168.1.20")
    client.succeed('ssh-keygen -q -t ed25519 -N "" -f /run/proxy-test-key')
    public_key = client.succeed("cat /run/proxy-test-key.pub")
    target.succeed("install -d -m700 /root/.ssh; printf %s " + shlex.quote(public_key) + " > /root/.ssh/authorized_keys")
    client.succeed("ssh -i /run/proxy-test-key -o UserKnownHostsFile=/run/proxy-known-hosts -o StrictHostKeyChecking=accept-new -o 'ProxyCommand=nc -x 127.0.0.1:10800 %h %p' root@198.51.100.30 printf proxy-ssh | grep -Fx proxy-ssh")
    intercepted_dns(client, "web.proxy.test", ["", compose_exec + " "], dual=True)
    assert client.succeed("curl -6 --noproxy '*' --cacert ${certificates.ca.cert} --max-time 10 -fsS https://proxy.test.nix:18087/dual").strip() in {"192.168.1.20", "2001:db8:10::20"}
    client.wait_for_unit("docker-site-apprise.service")
    client.wait_for_unit("docker-site-bark.service")
    client.wait_until_succeeds("su -s /bin/sh sender -c 'bark 首次启动通知'", timeout=180)
    # Pruning an unused network must coexist with the notification service's
    # stopped network; bringing the service back delivers a real notification.
    client.succeed("systemctl stop site-notification-network.service")
    notification_network = client.succeed("docker network inspect -f '{{.Id}}' site-notifications")
    client.succeed("docker network create disposable-workflow; systemctl start docker-prune.service", timeout=120)
    assert client.succeed("docker network inspect -f '{{.Id}}' site-notifications") == notification_network
    client.succeed("systemctl start site-notification-network.service", timeout=120)
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
    client.succeed(login + " --advertise-exit-node --snat-subnet-routes=true --shields-up=true")
    client.succeed("systemctl restart tailscaled-set.service")
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
    user("dig +short controlplane.tailscale.com A | grep -Fx 192.0.2.30")
    user("dig +short peer.fixture.ts.net A | grep -Fx " + peer4)
    target.succeed("grep '192.168.1.10 .*GET /key' /var/log/nginx/access.log")
    # A real Tailnet client selects this host as its dual-stack Internet exit.
    # Observe both clients at the destination through every later lifecycle event.
    client4 = client.succeed("tailscale ip -4").strip()
    peer.succeed(f"curl --noproxy '*' --max-time 6 -fsS http://{client4}:18080/tailnet | grep -Fx {peer4}")
    explicit_proxy(peer, client4)
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
            for name in ("exit.direct.test", "exit.proxy.test"):
                assert fake_address(peer, name, transport=transport) == fake_address(client, name)
        peer.succeed("dig +time=3 +tries=1 exit.blocked.test | grep NXDOMAIN")
        peer.succeed("dig +short client.fixture.ts.net A | grep -Fx " + client4)
        for name, source in (("exit.direct.test", "192.168.1.10"), ("exit.proxy.test", "192.168.1.20")):
            assert peer.succeed(f"curl -4 --noproxy '*' --max-time 8 -sSf http://{name}:18080/exit-domain").strip() == source
        client.wait_until_succeeds("journalctl --namespace=network -u site-dns-events -o cat --no-pager | network-dns-log --name exit.direct.test | grep '40-fixture.json/rules/2'")

    exit_dns()
    intercepted_dns(peer, "exit.proxy.test", [""], dual=True)
    def ipv4_healthy():
        client.wait_until_succeeds("network-ipv6 status", timeout=60)
        for machine in (client, peer):
            for host, source in (("192.0.2.30", "192.168.1.10"), ("198.51.100.30", "192.168.1.20")):
                machine.wait_until_succeeds("test $(curl --noproxy '*' --max-time 6 -sSf http://" + host + ":18080/ipv4-mode) = " + source, timeout=60)
            # Exit-node routes can recover before the peer receives its updated
            # PeerAPI DNS endpoint from the control plane.
            machine.wait_until_succeeds("dig +time=3 +tries=1 web.proxy.test AAAA | grep 'status: NOERROR'", timeout=60)
            fake_address(machine, "web.proxy.test")
            assert machine.succeed("dig +short web.proxy.test AAAA").strip() == ""
            machine.fail("curl --noproxy '*' --max-time 4 -sSf 'http://[2001:db8:2::30]:18080/ipv4-mode'")
        direct_ready()
        assert user("curl --noproxy '*' --max-time 8 -sSf http://" + peer4 + ":18083/tailnet.txt").strip() == "tailnet peer"
        exit_dns()
        container_web(client, "192.168.1.20")
        intercepted_dns(peer, "exit.proxy.test", [""])

    client.succeed("network-ipv6 off")
    ipv4_healthy()
    client.succeed("network-policy apply; systemctl reload nftables; systemctl restart site-dns sing-box site-network-connect")
    client.wait_until_succeeds("network-ipv6 status", timeout=60)
    ipv4_healthy()
    client.succeed("nmcli connection down underlay; nmcli connection up underlay")
    client.wait_until_succeeds("network-ipv6 status", timeout=90)
    ipv4_healthy()
    client.succeed("network-ipv6 on")
    healthy()
    fake_address(client, "web.proxy.test", "AAAA")
    client.succeed("systemctl restart docker")
    healthy()
    container_local(client)
    local_access()
    client.succeed(compose_command + " down; " + compose_command + " up -d", timeout=60)
    container_local(client)
    container_web(client, "192.168.1.20", ipv6=True)
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
    def publish_rules(domains):
        source = json.dumps({"version": 3, "rules": [{"domain": domains}]})
        upstream.succeed("printf '%s' " + shlex.quote(source) + " > /run/rule-source/domains.json; "
                         + "${pkgs.sing-box}/bin/sing-box rule-set compile /run/rule-source/domains.json -o /run/rule-source/domains.srs")
    def rules_status():
        return json.loads(user("network-policy rules-status"))
    initial_rules = rules_status()["active"]
    user("dig @127.0.0.1 -p 5300 +short initial.policy.example A | grep -Fx 192.0.2.30")
    publish_rules(["initial.policy.example", "updated.policy.example"])
    policy_pids = client.succeed("systemctl show site-dns sing-box -p MainPID")
    client.succeed("systemctl start site-network-rules-update")
    pending_rules = rules_status()["pending"]
    assert pending_rules and rules_status()["active"] == initial_rules
    assert client.succeed("systemctl show site-dns sing-box -p MainPID") == policy_pids
    user("dig @127.0.0.1 -p 5300 +short updated.policy.example A | grep -Fx 198.51.100.30")
    assert http("updated.policy.example") in {"192.168.1.20", "2001:db8:10::20"}
    # A malformed download retains both the usable rules and the validated candidate.
    upstream.succeed("printf invalid-srs > /run/rule-source/domains.srs")
    client.fail("systemctl start site-network-rules-update")
    assert rules_status()["pending"] == pending_rules
    client.succeed("systemctl start site-network-rules-apply@" + pending_rules["id"])
    healthy()
    assert rules_status()["active"] == pending_rules and rules_status()["pending"] is None
    user("dig @127.0.0.1 -p 5300 +short updated.policy.example A | grep -Fx 192.0.2.30")
    assert http("updated.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
    publish_rules(["initial.policy.example", "updated.policy.example", "pending.policy.example"])
    client.succeed("systemctl start site-network-rules-update")
    persisted_pending = rules_status()["pending"]
    checked = rules_status()["checked"]
    client.succeed("systemctl start site-network-rules-schedule")
    assert rules_status()["checked"] == checked
    generation = client.succeed("readlink /run/site-network-policy/current")
    client.succeed("install -d -m700 /var/lib/network-policy/route.d; printf '%s' '{\"rules\":[{\"rule_set\":\"missing\",\"outbound\":\"direct\"}]}' > /var/lib/network-policy/route.d/05-local.json")
    client.fail("network-policy apply")
    assert generation == client.succeed("readlink /run/site-network-policy/current")
    healthy()
    override = {"rules": [{"domain": ["live.policy.example", "private.home.arpa"], "outbound": "direct"}]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(override)) + " > /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    healthy()
    user("dig @127.0.0.1 -p 5300 +short live.policy.example A | grep -Fx 192.0.2.30")
    assert http("live.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
    user("dig +short private.home.arpa A | grep -Fx 192.0.2.30")
    dns_pid = client.succeed("systemctl show site-dns -p MainPID --value")
    connection = '// independent TCP routing\n{"rules":[{"domain":"live.policy.example","port":18080,"network":"tcp","outbound":"synthetic"},],}'
    client.succeed("install -d -m700 /var/lib/network-policy/connection.d; printf '%s' " + shlex.quote(connection) + " > /var/lib/network-policy/connection.d/03-work.jsonc; network-policy apply")
    healthy()
    user("dig @127.0.0.1 -p 5300 +short live.policy.example A | grep -Fx 192.0.2.30")
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
    for name, expected in (("direct.test", "192.0.2.30"), ("special.example.test", "198.51.100.30"),
                           ("api.other.test", "192.0.2.30"), ("apixother.test", "198.51.100.30")):
        for transport in ("", "+tcp"):
            user(f"dig @127.0.0.1 -p 5300 {transport} +short {name} A | grep -Fx {expected}")
            fake_address(client, name, transport=transport)
    user("dig private.home.arpa | grep NXDOMAIN")
    user("dig blocked.test | grep NXDOMAIN")
    # FakeIP restores the hostname and resolves through the shared DNS policy.
    # The egress host is the invariant for either client-facing address family;
    # healthy() checks each literal IPv4/IPv6 path separately above.
    for hostname, sources in (("web.direct.test", {"192.168.1.10", "2001:db8:10::10"}),
                              ("web.proxy.test", {"192.168.1.20", "2001:db8:10::20"})):
        observed = http(hostname)
        print(json.dumps({"hostname": hostname, "observed_source": observed}))
        assert observed in sources, (hostname, observed, sources)
    http("blocked.test", True)
    # Network records use their own journal while ordinary operational records
    # retain independent storage through rotation and reboot.
    client.succeed("printf '%s\\n' backup-history-fixture | systemd-cat -t backup-history-fixture")
    client.wait_until_succeeds("journalctl --namespace=network -u site-dns-events -o cat --no-pager | network-dns-log --name direct.test | grep '40-fixture.json/rules/2'")
    client.wait_until_succeeds("journalctl --namespace=network -u site-dns-race-cn -o cat --no-pager | grep direct.test")
    client.succeed("python3 -c 'import dns.message,dns.query; from pathlib import Path; r=dns.query.tcp(dns.message.make_query(\"large.direct.test\",\"TXT\"),\"127.0.0.1\",port=5300); assert r.answer[0][0].strings==(b\"x\"*200,)*200; Path(\"/run/large-answer.wire\").write_bytes(r.to_wire(max_size=65535))'")
    client.wait_until_succeeds("journalctl --namespace=network -u site-dns-events -o cat --no-pager | network-dns-log --name large.direct.test > /run/large-events.jsonl; python3 -c 'import json,dns.message; from pathlib import Path; expected=dns.message.from_wire(Path(\"/run/large-answer.wire\").read_bytes()).answer; events=[json.loads(line) for line in Path(\"/run/large-events.jsonl\").read_text().splitlines()]; assert any(e[\"identity\"]==\"dnsdist-client\" and dns.message.from_text(e[\"dns\"]).answer==expected for e in events)'")
    client.succeed("journalctl --namespace=network -u sing-box -o cat --no-pager | grep DEBUG")
    client.succeed("journalctl -u mullvad-daemon -o cat --no-pager | grep DEBUG")
    pids = client.succeed("systemctl show mullvad-daemon sing-box site-dns -p MainPID")
    client.succeed("python3 -c 'from pathlib import Path; p=Path(\"/var/log/mullvad-vpn/daemon.log\"); p.open(\"a\").write(\"rotation-fixture\\n\" * 1200000)'")
    client.succeed("systemctl start site-network-logrotate; gzip -t /var/log/mullvad-vpn/daemon.log.1.gz")
    healthy()
    assert pids == client.succeed("systemctl show mullvad-daemon sing-box site-dns -p MainPID")
    client.succeed("journalctl --namespace=network --sync; journalctl --namespace=network --rotate")
    client.succeed("journalctl -t backup-history-fixture -o cat --no-pager | grep -Fx backup-history-fixture")
    client.succeed("test -z \"$(journalctl _SYSTEMD_UNIT=site-dns-events.service -o cat --no-pager)\"")
    user("dig @127.0.0.1 -p 5300 +short after-rotation.direct.test A | grep -Fx 192.0.2.30")
    client.wait_until_succeeds("journalctl --namespace=network -u site-dns-events -o cat --no-pager | network-dns-log --name after-rotation.direct.test | grep 192.0.2.30")
    upstream.fail("nc -z -w2 192.168.1.10 5300")
    # Shared DNS returns one real address for both names. The transparent
    # endpoint retains their separate connection policies for TCP and UDP.
    connection = {"rules": [
        {"domain": "foo.proxy.test", "outbound": "direct"},
        {"domain": "bar.proxy.test", "outbound": "synthetic"},
    ]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(connection)) + " > /var/lib/network-policy/connection.d/04-fakeip.json; network-policy apply")
    healthy()
    for name in ("foo.proxy.test", "bar.proxy.test"):
        user(f"dig @127.0.0.1 -p 5300 +short {name} A | grep -Fx 198.51.100.30")
    for kind in ("A", "AAAA"):
        first, second = (fake_address(client, name, kind) for name in ("foo.proxy.test", "bar.proxy.test"))
        assert first != second
        opaque_egress(first, {"192.168.1.10", "2001:db8:10::10"})
        opaque_egress(second, {"192.168.1.20", "2001:db8:10::20"})
    client.succeed("rm /var/lib/network-policy/connection.d/04-fakeip.json; network-policy apply")
    exclusions = {"domain": ["real.proxy.test"], "domain_suffix": ["native.proxy.test"]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(exclusions)) + " > /var/lib/network-policy/fakeip-exclude.jsonc; network-policy apply")
    healthy()
    for name in ("real.proxy.test", "app.native.proxy.test"):
        user(f"dig +short {name} A | grep -Fx 198.51.100.30")
        assert http(name) in {"192.168.1.20", "2001:db8:10::20"}
    persistent_fake4 = fake_address(client, "web.direct.test")
    persistent_fake6 = fake_address(client, "web.direct.test", "AAAA")
    client.succeed("systemctl restart sing-box")
    healthy()
    opaque_egress(persistent_fake4, {"192.168.1.10", "2001:db8:10::10"})
    opaque_egress(persistent_fake6, {"192.168.1.10", "2001:db8:10::10"})
    # A single unbound UDP socket changes destinations without retaining its old policy.
    code = "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4); "
    code += "s.sendto(b'direct-udp',('192.0.2.30',18081)); assert s.recv(100)==b'192.168.1.10'; "
    code += "s.sendto(b'proxy-udp',('198.51.100.30',18081)); assert s.recv(100)==b'192.168.1.20'"
    user("python3 -c " + shlex.quote(code))
    user("ping -c1 -W2 198.51.100.30", True)
    user("ping -6 -c1 -W2 2001:db8:2::30", True)
    client.succeed("systemctl reload nftables")
    healthy()
    upstream.succeed("systemctl stop proxy")
    tailnet()
    http("198.51.100.30", True)
    assert http("192.0.2.30") == "192.168.1.10"
    peer.fail("curl --noproxy '*' --max-time 6 -sSf http://198.51.100.30:18080/exit-proxy-loss")
    assert peer.succeed("curl --noproxy '*' --max-time 6 -sSf http://192.0.2.30:18080/exit-direct").strip() == "192.168.1.10"
    upstream.succeed("systemctl start proxy")
    healthy()
    for unit in ("sing-box", "site-network-routing", "mullvad-daemon"):
        client.succeed("systemctl stop " + unit)
        tailnet()
        local_access()
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
    status, observed = client.execute("su -s /bin/sh desktop -c " + shlex.quote("curl --noproxy '*' --max-time 6 -sSf http://198.51.100.30:18080/daemon-loss"))
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
          + interface + " --max-time 5 -fsS http://192.0.2.30:18080/interface | grep -Fx 192.168.1.20", timeout=60)
    healthy()
    dns_pids = client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
    provider["outbounds"][0]["tag"] = "second-node"
    provider_text = shlex.quote("// synthetic nodes\n" + json.dumps(provider))
    client.succeed("echo " + provider_text + " > /run/provider.json; network-policy apply")
    assert dns_pids == client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
    healthy()
    # A user apply also recovers an unchanged policy from failed or backoff state.
    client.succeed("systemctl stop site-network-underlay")
    for state, restart in (("failed", "no"), ("activating", "on-failure")):
        override = "[Service]\nExecStartPre=/run/current-system/sw/bin/false\nRestart=" + restart + "\nRestartSec=1h\n"
        client.succeed("mkdir -p /run/systemd/system/sing-box.service.d; printf %s " + shlex.quote(override) + " > /run/systemd/system/sing-box.service.d/recovery-fixture.conf; systemctl daemon-reload")
        client.fail("systemctl restart sing-box")
        client.wait_until_succeeds("test $(systemctl show sing-box -p ActiveState --value) = " + state)
        client.succeed("rm /run/systemd/system/sing-box.service.d/recovery-fixture.conf; systemctl daemon-reload; network-policy apply")
        assert dns_pids == client.succeed("systemctl show site-dns site-dns-race-cn site-dns-race-global -p MainPID")
        healthy()
    client.succeed("systemctl start site-network-underlay")
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
    client.succeed("network-ipv6 on")
    healthy()
    client.succeed("nmcli connection down underlay")
    blocked()
    client.wait_until_succeeds("python3 -c 'import json; state=json.load(open(\"/run/site-network-underlay/underlay.json\")); assert state is None or state[\"interface\"] != \"eth1\"'", timeout=30)
    client.succeed("nmcli connection up underlay")
    ready_underlay()
    healthy()
    persistent = {"rules": [{"domain": "persisted.policy.example", "outbound": "direct"}]}
    client.succeed("printf '%s' " + shlex.quote(json.dumps(persistent)) + " > /var/lib/network-policy/route.d/05-local.json; network-policy apply")
    client.succeed("journalctl --namespace=network --sync; journalctl --sync")
    # The observer remains running through both orderly and abrupt power loss.
    for shutdown, preserve_fakeip in ((client.shutdown, True), (client.crash, False)):
        client.succeed("network-ipv6 on")
        healthy()
        opaque_egress(persistent_fake4, {"192.168.1.10", "2001:db8:10::10"})
        opaque_egress(persistent_fake6, {"192.168.1.10", "2001:db8:10::10"})
        shutdown()
        client.start()
        client.wait_for_unit("multi-user.target")
        client.succeed("journalctl --namespace=network -u site-dns-events -o cat --no-pager | network-dns-log --name after-rotation.direct.test | grep 192.0.2.30")
        client.succeed("journalctl -t backup-history-fixture -o cat --no-pager | grep -Fx backup-history-fixture")
        client.succeed("test -s /var/log/mullvad-vpn/daemon.log.1.gz")
        blocked()  # runtime provider deliberately absent; no permissive startup.
        client.wait_for_unit("tailscaled.service")
        client.wait_until_succeeds(direct_ping, timeout=90)
        ready_underlay()
        client.succeed("install -m600 /dev/null /run/provider.json; echo " + provider_text + " > /run/provider.json; network-policy apply")
        ipv4_healthy()
        client.succeed("network-ipv6 on")
        tailnet()
        healthy()
        client.succeed("network-ipv6 status")
        container_local(client)
        if preserve_fakeip:
            opaque_egress(persistent_fake4, {"192.168.1.10", "2001:db8:10::10"})
            opaque_egress(persistent_fake6, {"192.168.1.10", "2001:db8:10::10"})
            assert fake_address(client, "web.direct.test") == persistent_fake4
            assert fake_address(client, "web.direct.test", "AAAA") == persistent_fake6
        else:
            # After abrupt power loss, clients recover by resolving again.
            for kind in ("A", "AAAA"):
                opaque_egress(fake_address(client, "web.direct.test", kind), {"192.168.1.10", "2001:db8:10::10"})
        user("dig @127.0.0.1 -p 5300 +short persisted.policy.example A | grep -Fx 192.0.2.30")
        assert rules_status()["active"] == pending_rules
        assert rules_status()["pending"] == persisted_pending
        user("dig @127.0.0.1 -p 5300 +short updated.policy.example A | grep -Fx 192.0.2.30")
        user("dig @127.0.0.1 -p 5300 +short pending.policy.example A | grep -Fx 198.51.100.30")
        assert http("persisted.policy.example") in {"192.168.1.10", "2001:db8:10::10"}
        assert fake_address(peer, "persisted.policy.example") == fake_address(client, "persisted.policy.example")
        exit_dns()
    client.succeed("systemctl stop continuous")
    peer.succeed("systemctl stop exit-continuous")
    target.succeed("flock --shared /run/observations.jsonl cp /run/observations.jsonl /run/observations-final.jsonl")
    target.copy_from_machine("/run/observations-final.jsonl", "network")
    from pathlib import Path
    observation_file = Path(target.out_dir) / "network/observations-final.jsonl"
    observations = []
    with observation_file.open() as stream:
        for number, line in enumerate(stream, 1):
            try:
                observations.append(json.loads(line))
            except json.JSONDecodeError as error:
                excerpt = line[max(0, error.pos - 80):error.pos + 80]
                raise AssertionError(f"{observation_file}:{number}: column {error.colno}: {error.msg}; near {excerpt!r}") from error
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
    client.shutdown()
    peer.shutdown()
  '';
}
