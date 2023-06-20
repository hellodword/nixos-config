{ persistPath, ... }:

{
  services.flatpak = {
    enable = true;
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/flatpak"
    ];
  };
}
