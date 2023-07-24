{ pkgs, ... }:

{
  services.xserver = {
    enable = true;
  };

  # https://github.com/localsend/localsend/tree/main/lib/provider/network
  environment.systemPackages = with pkgs; [
    localsend
    xvfb-run
  ];

  # TODO dart cli

  systemd.user.services."localsend" = {
    enable = true;
    unitConfig = {
      After = [ "network.target" ];
    };
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.xorg.xorgserver}/bin/Xvfb :99 -screen 0 1024x768x24 +extension GLX +render"
      ];
      ExecStart = "${pkgs.xvfb-run}/bin/xvfb-run ${pkgs.localsend}/bin/localsend";
    };
  };
}
