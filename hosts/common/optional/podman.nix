{ persistPath, userName, ... }:

{
  users.users."${userName}".extraGroups = [ "podman" ];

  virtualisation.podman = {
    enable = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ ];
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/containers"
    ];
  };
}
