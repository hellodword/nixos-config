{ persistPath, ... }:

let
  INTERFACE_NAME = "wg0";
  CONFIG_DIR = "/usr/local/etc/wireguard";
  CONFIG_FILE = "${persistPath}${CONFIG_DIR}/${INTERFACE_NAME}.conf";
in
{
  # Wireguard doesn’t really use the concept of client and server

  # wg genkey | tee wg.priv | wg pubkey > wg.pub; cat wg.priv wg.pub

  # # server
  # [Interface]
  # Address = 172.222.1.1/24, 2001:8b0:2c1:222::1/64
  # ListenPort = 8001
  # PrivateKey = <...>
  # [Peer]
  # PublicKey = <...>
  # AllowedIPs = 172.222.1.2/32,172.222.1.0/24,2001:8b0:2c1:222::2/128
  # Endpoint = <client>:8001
  # PersistentKeepalive = 25

  # # client
  # [Interface]
  # Address = 172.222.1.2/24, 2001:8b0:2c1:222::2/128
  # ListenPort = 8001
  # PrivateKey = <...>
  # [Peer]
  # PublicKey = <...>
  # AllowedIPs = 0.0.0.0/0, ::0/0
  # Endpoint = <server>:8001
  # PersistentKeepalive = 25

  systemd.network.wait-online.ignoredInterfaces = [ INTERFACE_NAME ];
  networking.wg-quick.interfaces."${INTERFACE_NAME}".configFile = CONFIG_FILE;

  environment.persistence = {
    "${persistPath}".directories = [
      CONFIG_DIR
    ];
  };
}
