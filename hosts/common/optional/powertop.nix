{ pkgs, persistPath, ... }:

{
  environment.systemPackages = with pkgs; [ powertop ];

  powerManagement.powertop = {
    enable = true;
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/cache/powertop"
    ];
  };
}
