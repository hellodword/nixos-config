{
  interface = "wg0-mullvad";
  table = 1836018789;
  mark = "0x6d6f6c65";
  ctMark = "0xf41";
  exclusionCgroup = "/mullvad-exclusions";
  settingsVersion = 17;
  peer = {
    port = 51820;
    clientIPv4 = "10.67.0.2";
    clientIPv6 = "fd66:105::2";
    gatewayIPv4 = "10.67.0.1";
    gatewayIPv6 = "fd66:105::1";
  };
}
