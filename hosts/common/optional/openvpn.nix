{ persistPath, ... }:

{
  environment.persistence = {
    "${persistPath}".directories = [
      "/usr/local/etc/openvpn/client"
    ];
  };
}
