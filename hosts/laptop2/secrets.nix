{
  config,
  lib,
  userName,
  hostSecretsDirectory,
  ...
}:
let
  yaml = group: key: {
    sopsFile = hostSecretsDirectory + "/${group}.sops.yaml";
    inherit key;
  };
  secret = name: config.sops.secrets.${name}.path;
  providers = {
    scaleway = { };
    r2 = { };
    b2 = { };
  };
in
{
  _module.args.hostSecretsDirectory = lib.mkDefault ./secrets;

  users.users.${userName}.hashedPasswordFile = secret "${userName}-password";
  services.tailscale.authKeyFile = lib.mkIf config.services.tailscale.enable (
    secret "tailscale-auth-key"
  );
  site.cli.identityFile = secret "personal-identity";
  site.backup.targets = lib.mapAttrs (name: _: {
    repositoryFile = secret "restic-repo-${name}";
    passwordFile = secret "restic-password";
    environmentFile = secret "restic-s3-${name}";
  }) providers;
  site.notifications = {
    barkDeviceTokenFile = secret "bark-device-token";
    extraConfigFile = secret "notification-channels";
    users = [ userName ];
  };
  sops.secrets = {
    "${userName}-password" = (yaml "system" "login/passwordHash") // {
      neededForUsers = true;
    };
    tailscale-auth-key = lib.mkIf config.services.tailscale.enable (yaml "system" "tailscale/authKey");
    restic-password = yaml "backup" "password";
    bark-device-token = (yaml "system" "notifications/barkDeviceToken") // {
      restartUnits = [ "site-notification-secrets.service" ];
    };
    notification-channels = {
      sopsFile = hostSecretsDirectory + "/system.sops.yaml";
      key = "notifications/channels";
      restartUnits = [ "site-notification-secrets.service" ];
    };
    wifi-environment = lib.mkIf (config.networking.networkmanager.ensureProfiles.profiles != { }) {
      sopsFile = hostSecretsDirectory + "/system.sops.yaml";
      key = "wifi/environment";
      restartUnits = [ "NetworkManager-ensure-profiles.service" ];
    };
    personal-identity = {
      sopsFile = hostSecretsDirectory + "/identity.sops.yaml";
      key = "";
      mode = "0400";
      restartUnits = [ "site-identity.service" ];
    };
  }
  // lib.mapAttrs' (
    name: _: lib.nameValuePair "restic-repo-${name}" (yaml "backup" "repositories/${name}/url")
  ) providers
  // lib.mapAttrs' (
    name: _: lib.nameValuePair "restic-s3-${name}" (yaml "backup" "repositories/${name}/environment")
  ) providers;

  networking.networkmanager.ensureProfiles.environmentFiles = lib.optional (
    config.networking.networkmanager.ensureProfiles.profiles != { }
  ) (secret "wifi-environment");
  # Public profile aliases reference SSID/password variables from wifi/environment.
  # SSIDs and passwords are substituted from wifi/environment after decryption.
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
