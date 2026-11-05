{ lib }:
{
  lockdown ? false,
  dns ? true,
  dnsPort ? 5300,
  bootstrapPort ? 5301,
  mixedPort ? 10800,
  directNetworks ? [ ],
  blockedNetworks ? [ ],
  ipRuleSets ? [ ],
  tailscale ? false,
}:
{
  log = {
    level = "debug";
    timestamp = true;
  };
  dns = {
    servers =
      if !dns then
        [
          {
            type = "local";
            tag = "dns-policy";
          }
        ]
      else
        [
          {
            type = "tcp";
            tag = "dns-policy";
            server = "127.0.0.1";
            server_port = dnsPort;
            detour = "local";
          }
          {
            type = "tcp";
            tag = "dns-bootstrap";
            server = "127.0.0.1";
            server_port = bootstrapPort;
            detour = "local";
          }
        ];
    final = "dns-policy";
    # The selected resolver owns caching. Keep only domain/IP associations.
    disable_cache = true;
    reverse_mapping = true;
  };
  inbounds = lib.optionals (!lockdown) [
    {
      type = "mixed";
      tag = "mixed";
      listen = "127.0.0.1";
      listen_port = mixedPort;
    }
    {
      type = "mixed";
      tag = "mixed-v6";
      listen = "::1";
      listen_port = mixedPort;
    }
  ];
  endpoints = lib.optional lockdown {
    type = "wireguard";
    tag = "transparent";
    system = false;
    mtu = 1280;
    address = [
      "10.67.0.1/32"
      "fd66:105::1/128"
    ];
    listen_port = 51820;
    bind_interface = "lo";
    peers = [
      {
        allowed_ips = [
          "10.67.0.2/32"
          "fd66:105::2/128"
        ];
      }
    ];
    udp_mapping = "address_and_port_dependent";
    udp_filtering = "address_and_port_dependent";
  };
  outbounds = [
    {
      type = "direct";
      tag = "local";
      bind_interface = "lo";
    }
    {
      type = "direct";
      tag = "direct";
      domain_resolver = {
        server = "dns-policy";
        strategy = "prefer_ipv4";
      };
    }
    {
      type = "direct";
      tag = "private";
      domain_resolver = {
        server = "dns-policy";
        strategy = "prefer_ipv4";
      };
    }
    {
      type = "urltest";
      tag = "auto";
      outbounds = [ ];
      interval = "5m";
      tolerance = 100;
    }
    {
      type = "selector";
      tag = "proxy";
      outbounds = [ "auto" ];
      default = "auto";
    }
  ]
  ++ lib.optional tailscale {
    type = "direct";
    tag = "tailnet";
    bind_interface = "tailscale0";
    domain_resolver = {
      server = "dns-policy";
      strategy = "prefer_ipv4";
    };
  };
  route = {
    # A runtime underlay selector supplies an explicit physical interface when
    # Lockdown is enabled. Detecting the Mullvad tunnel here would create a loop.
    auto_detect_interface = !lockdown;
    default_domain_resolver = {
      server = if dns then "dns-bootstrap" else "dns-policy";
      strategy = "prefer_ipv4";
    };
    rule_set = [ ];
    final = "proxy";
    rules =
      lib.optional lockdown {
        inbound = [ "transparent" ];
        network = "icmp";
        action = "reject";
        method = "drop";
      }
      ++ [
        {
          action = "sniff";
          sniffer = [
            "http"
            "tls"
            "dns"
          ];
        }
        {
          port = 53;
          action = "hijack-dns";
        }
        {
          protocol = "dns";
          action = "hijack-dns";
        }
      ]
      ++ lib.optional (blockedNetworks != [ ]) {
        ip_cidr = blockedNetworks;
        action = "reject";
      };
  };
  _connectionFragments = {
    "96-private-ip.json".rules = [
      {
        ip_is_private = true;
        action = "route";
        outbound = "direct";
      }
    ];
  }
  // lib.optionalAttrs tailscale {
    "95-tailnet-ip.json".rules = [
      {
        ip_cidr = [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
        ];
        action = "route";
        outbound = "tailnet";
      }
    ];
  }
  // lib.optionalAttrs (directNetworks != [ ]) {
    "97-direct-ip.json".rules = [
      {
        ip_cidr = directNetworks;
        action = "route";
        outbound = "direct";
      }
    ];
  }
  // lib.optionalAttrs (ipRuleSets != [ ]) {
    "98-geoip.json" = {
      rule_set = ipRuleSets;
      rules = [
        {
          rule_set = map (r: r.tag) ipRuleSets;
          action = "route";
          outbound = "direct";
        }
      ];
    };
  };
  experimental.cache_file = {
    enabled = true;
    path = "cache.db";
  };
}
