{ userName, ... }:
{
  imports = [
    (import ../../lib/credentials.nix {
      inherit userName;
      hostSecretsDirectory = ./secrets;
      backupTargets = [
        "scaleway"
        "r2"
        "b2"
      ];
    })
  ];
  networking.networkmanager.ensureProfiles.profiles = {
    home = {
      connection = {
        id = "home";
        uuid = "6b22898e-fb9f-4f8f-898a-bcfeab806ed3";
        type = "wifi";
        autoconnect = true;
      };
      wifi.ssid = "$HOME_SSID";
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$HOME_PSK";
      };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
    TRAVEL = {
      connection = {
        id = "work";
        uuid = "471b395e-4514-4fab-9d27-7ec75815ce90";
        type = "wifi";
        autoconnect = true;
      };
      wifi.ssid = "$TRAVEL_SSID";
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$TRAVEL_PSK";
      };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
    IPHONE = {
      connection = {
        id = "iphone";
        uuid = "399ca6ce-b601-4143-affd-33639d85a8a7";
        type = "wifi";
        autoconnect = true;
      };
      wifi.ssid = "$IPHONE_SSID";
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$IPHONE_PSK";
      };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
    MIFI = {
      connection = {
        id = "mifi";
        uuid = "927f4000-eeb1-458c-8ed3-c82cfb98fdb5";
        type = "wifi";
        autoconnect = true;
      };
      wifi.ssid = "$MIFI_SSID";
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$MIFI_PSK";
      };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
  };
}
