{ inputs, config, persistPath, ... }:

{
  imports = [
    inputs.sops-nix.homeManagerModules.sops
  ];

  sops = {
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys_home_manager.txt";
    age.generateKey = false;
  };

  home.persistence = {
    "${persistPath}${config.home.homeDirectory}".directories = [ ".config/sops/age" ];
  };
}
