"""Mullvad daemon routing, packet mark and exclusion contract constants."""

INTERFACE = "wg0-mullvad"
TUNNEL_TABLE = 1836018789  # 0x6d6f6c65
MARK_HEX = "0x6d6f6c65"
CT_MARK_HEX = "0xf41"
EXCLUSION_CGROUP = "/mullvad-exclusions"
SETTINGS_VERSION = 17

PEER_PORT = 51820
CLIENT4 = "10.67.0.2"
CLIENT6 = "fd66:105::2"
GATE4 = "10.67.0.1"
GATE6 = "fd66:105::1"

CONTRACT = {
    "interface": INTERFACE,
    "table": TUNNEL_TABLE,
    "mark": MARK_HEX,
    "ctMark": CT_MARK_HEX,
    "exclusionCgroup": EXCLUSION_CGROUP,
    "settingsVersion": SETTINGS_VERSION,
    "peer": {
        "port": PEER_PORT,
        "clientIPv4": CLIENT4,
        "clientIPv6": CLIENT6,
        "gatewayIPv4": GATE4,
        "gatewayIPv6": GATE6,
    },
}
