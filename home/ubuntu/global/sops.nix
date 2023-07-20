{ lib, config, ... }:

{
  # imports = [
  #   inputs.sops-nix.homeManagerModules.sops
  # ];

  # sops = {
  #   age.sshKeyPaths = [ ];
  #   gnupg.sshKeyPaths = [ ];
  #   age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys_home_manager.txt";
  #   age.generateKey = false;
  # };

  # home.persistence = {
  #   "${persistPath}${config.home.homeDirectory}".directories = [ ".config/sops/age" ];
  # };

  home.activation.createSopsDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p ${config.home.homeDirectory}/.config/sops/age
  '';
}
