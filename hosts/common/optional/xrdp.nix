{ pkgs, persistPath, ... }:

{
  services.xrdp = {
    enable = true;
    defaultWindowManager = "i3";
  };

  systemd.services."xrdp" = {
    serviceConfig = {
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/chown root:xrdp /etc/xrdp/cert.pem"
        "+${pkgs.coreutils}/bin/chmod 440 /etc/xrdp/cert.pem"
        "+${pkgs.coreutils}/bin/chown root:xrdp /etc/xrdp/key.pem"
        "+${pkgs.coreutils}/bin/chmod 440 /etc/xrdp/key.pem"
      ];
    };
  };

  environment.persistence = {
    "${persistPath}" = {
      files = [
        "/etc/xrdp/cert.pem"
        "/etc/xrdp/key.pem"
      ];
    };
  };
}
