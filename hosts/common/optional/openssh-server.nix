{ persistPath, ... }:

{
  services.openssh = {
    enable = true;

    hostKeys = [
      {
        bits = 4096;
        path = "/etc/ssh/ssh_host_rsa_key";
        type = "rsa";
        rounds = 1000;
      }
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
        rounds = 1000;
      }
    ];
  };

  environment.persistence = {
    "${persistPath}" = {
      files = [
        # "/etc/ssh/ssh_host_ecdsa_key.pub"
        # "/etc/ssh/ssh_host_ecdsa_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
      ];
    };
  };

  # services.borgbackup.jobs."ssh-hostkeys" = {
  #   repo = "${persistPath}/borgbackup/ssh-hostkeys";
  #   appendFailedSuffix = true;
  #   compression = "auto,zstd,3";
  #   doInit = true;
  #   encryption = {
  #     mode = "repokey";
  #     # passphrase = "123";
  #     passCommand = "cat ${config.sops.secrets."borgbackup".path}";
  #   };
  #   # environment = {
  #   #   BORG_RSH = "ssh -i /path/to/key";
  #   # };
  #   user = "root";
  #   group = "root";
  #   startAt = "daily";
  #   prune = {
  #     keep = {
  #       within = "2d"; # Keep all archives from the last day
  #       daily = 7;
  #       weekly = 4;
  #       monthly = -1; # Keep at least one archive for each month
  #     };
  #   };

  #   paths = [
  #     "/etc/ssh/ssh_host_ed25519_key.pub"
  #     "/etc/ssh/ssh_host_ed25519_key"
  #     "/etc/ssh/ssh_host_rsa_key.pub"
  #     "/etc/ssh/ssh_host_rsa_key"
  #   ];
  # };
}
