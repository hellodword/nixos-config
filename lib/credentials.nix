{
  hostSecretsDirectory,
  userName,
  backupTargets,
}:
{
  config,
  lib,
  ...
}:
let
  yaml = group: key: {
    sopsFile = hostSecretsDirectory + "/${group}.sops.yaml";
    inherit key;
  };
  secret = name: config.sops.secrets.${name}.path;
  providers = lib.genAttrs backupTargets (_: { });
in
{
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
  site.files = lib.mkIf config.site.files.enable {
    adminPasswordFile = secret "files-admin-password";
    guestPasswordFile = secret "files-guest-password";
    certificateConfigFile = secret "files-certificate-config";
  };
  sops.secrets = {
    # Whole-document extraction preserves arrays for the root-only signing command.
    files-certificate-config = lib.mkIf config.site.files.enable (yaml "system" "");
    files-admin-password = lib.mkIf config.site.files.enable (
      (yaml "system" "files/adminPassword")
      // {
        restartUnits = [
          "site-files-accounts.service"
        ];
      }
    );
    files-guest-password = lib.mkIf config.site.files.enable (
      (yaml "system" "files/guestPassword")
      // {
        restartUnits = [
          "site-files-accounts.service"
        ];
      }
    );
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
}
