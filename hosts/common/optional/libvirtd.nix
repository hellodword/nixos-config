{ persistPath, ... }:

{
  virtualisation.libvirtd = {
    enable = true;
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/libvirt"
    ];
  };
}
