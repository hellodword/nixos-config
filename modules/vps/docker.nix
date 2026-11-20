{ ... }:
{
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    daemon.settings = {
      ip-forward-no-drop = true;
      log-driver = "local";
    };
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  networking.firewall.extraForwardRules = ''
    iifname "docker0" accept
    iifname "br-*" accept
  '';
}
