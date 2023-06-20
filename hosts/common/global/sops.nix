{ inputs, persistPath, ... }:
# let
#   isEd25519 = k: k.type == "ed25519";
#   getKeyPath = k: k.path;
#   keys = builtins.filter isEd25519 config.services.openssh.hostKeys;
# in
{
  imports = [
    inputs.sops-nix.nixosModules.sops
  ];

  sops = {
    # https://github.com/Mic92/sops-nix/blob/36b062a2c85a0efb37de1300c79c54602a094fab/pkgs/sops-install-secrets/main.go#L939-L950
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
    age.keyFile = "${persistPath}/var/lib/sops-nix/keys.txt";
    age.generateKey = false;
  };

  # sops.secrets."borgbackup" = {
  #   sopsFile = ../../${config.networking.hostName}/secrets/secrets.yaml;
  # };

  # system.activationScripts.make-borgbackup-base-public.text = ''
  #   mkdir -p "${persistPath}/borgbackup"
  #   chown 1000 "${persistPath}/borgbackup"
  # '';

  # system.activationScripts.protect-age-keys.text = ''
  #   chown -R root:root "${persistPath}/var/lib/sops-nix"
  #   chmod 0700 "${persistPath}/var/lib/sops-nix"
  #   chmod 600 "${persistPath}/var/lib/sops-nix/keys.txt"
  # '';
}
