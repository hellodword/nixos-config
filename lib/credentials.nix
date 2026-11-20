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
  backupEnabled = config.site.backup.enable && backupTargets != [ ];
  providers = lib.genAttrs backupTargets (_: { });
in
{
  users.users.${userName}.hashedPasswordFile = secret "${userName}-password";
  services.tailscale.authKeyFile = lib.mkIf config.services.tailscale.enable (
    secret "tailscale-auth-key"
  );
  site.cli.identityFile = lib.mkIf config.site.cli.enable (secret "personal-identity");
  site.backup.targets = lib.mapAttrs (name: _: {
    repositoryFile = lib.mkIf backupEnabled (secret "restic-repo-${name}");
    passwordFile = lib.mkIf backupEnabled (secret "restic-password");
    environmentFile = lib.mkIf backupEnabled (secret "restic-s3-${name}");
  }) providers;
  site.notifications = lib.mkIf config.site.notifications.enable {
    barkDeviceTokenFile = secret "bark-device-token";
    extraConfigFile = secret "notification-channels";
    users = [ userName ];
  };
  site.files = lib.mkIf config.site.files.enable {
    adminPasswordFile = secret "files-admin-password";
    userPasswordFile = secret "files-user-password";
    certificateConfigFile = secret "files-certificate-config";
  };
  sops.secrets = lib.mkMerge [
    {
      "${userName}-password" = (yaml "system" "login/passwordHash") // {
        neededForUsers = true;
      };
    }
    (lib.mkIf config.site.files.enable {
      files-certificate-config = yaml "system" "files/certificateNames";
      files-admin-password = (yaml "system" "files/adminPassword") // {
        restartUnits = [ "site-files-accounts.service" ];
      };
      files-user-password = (yaml "system" "files/userPassword") // {
        restartUnits = [ "site-files-accounts.service" ];
      };
    })
    (lib.mkIf config.services.tailscale.enable {
      tailscale-auth-key = yaml "system" "tailscale/authKey";
    })
    (lib.mkIf backupEnabled (
      {
        restic-password = yaml "backup" "password";
      }
      // lib.mapAttrs' (
        name: _: lib.nameValuePair "restic-repo-${name}" (yaml "backup" "repositories/${name}/url")
      ) providers
      // lib.mapAttrs' (
        name: _: lib.nameValuePair "restic-s3-${name}" (yaml "backup" "repositories/${name}/environment")
      ) providers
    ))
    (lib.mkIf config.site.notifications.enable {
      bark-device-token = (yaml "system" "notifications/barkDeviceToken") // {
        restartUnits = [ "site-notification-secrets.service" ];
      };
      notification-channels = {
        sopsFile = hostSecretsDirectory + "/system.sops.yaml";
        key = "notifications/channels";
        restartUnits = [ "site-notification-secrets.service" ];
      };
    })
    (lib.mkIf (config.networking.networkmanager.ensureProfiles.profiles != { }) {
      wifi-environment = {
        sopsFile = hostSecretsDirectory + "/system.sops.yaml";
        key = "wifi/environment";
        restartUnits = [ "NetworkManager-ensure-profiles.service" ];
      };
    })
    (lib.mkIf config.site.cli.enable {
      personal-identity = {
        sopsFile = hostSecretsDirectory + "/identity.sops.yaml";
        key = "";
        mode = "0400";
        restartUnits = [ "site-identity.service" ];
      };
    })
  ];

  networking.networkmanager.ensureProfiles.environmentFiles = lib.optional (
    config.networking.networkmanager.ensureProfiles.profiles != { }
  ) (secret "wifi-environment");
  # Public profile aliases reference SSID/password variables from wifi/environment.
  # SSIDs and passwords are substituted from wifi/environment after decryption.
}
