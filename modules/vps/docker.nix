{ ... }:
{
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    daemon.settings.ip-forward-no-drop = true;
  };

  networking.firewall.extraForwardRules = ''
    iifname "docker0" accept
    iifname "br-*" accept
  '';
}
