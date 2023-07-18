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
}
