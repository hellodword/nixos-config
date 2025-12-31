{ persistPath, userName, ... }:

{
  users.users."${userName}".extraGroups = [ "libvirtd" ];

  virtualisation.libvirtd = {
    enable = true;
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/lib/libvirt"
    ];
  };
}
