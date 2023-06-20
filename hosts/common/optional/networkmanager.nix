{ persistPath, ... }:

{
  environment.persistence = {
    "${persistPath}".directories = [
      "/etc/NetworkManager/system-connections"
    ];
  };
}
