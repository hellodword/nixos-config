{ inputs, ... }:

{
  imports = [ inputs.impermanence.nixosModules.home-manager.impermanence ];

  home.persistence = {
    "/persist/home/admin".directories = [
      ".config/Bitwarden"
      ".config/Bitwarden CLI"
    ];
  };
}
