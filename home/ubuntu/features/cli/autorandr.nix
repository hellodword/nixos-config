{ pkgs, config, ... }:

let
  autorandr-trigger = pkgs.writeShellApplication {
    name = "autorandr-trigger";
    text = ''
      while (true);
      do
        udevadm monitor --udev --subsystem-match=drm | \
          while read -r l ; do
            if [[ "$l" == *"change"* ]]; then
              ${config.systemd.user.services.autorandr.Service.ExecStart}
            fi
          done
      done
    '';
  };
in
{

  # systemd.user.services.autorandr.Unit.After = [ "sops-nix.service" ];
  services.autorandr.enable = true;
  # systemd.user.timers.autorandr = {
  #   Timer = {
  #     OnBootSec = "30s";
  #     OnUnitInactiveSec = "5s";
  #     AccuracySec = "1us";
  #   };
  #   Install = { WantedBy = [ "timers.target" ]; };
  # };
  systemd.user.services.autorandr-trigger = {
    Unit = {
      Description = "autorandr trigger";
      After = config.systemd.user.services.autorandr.Unit.After;
      PartOf = config.systemd.user.services.autorandr.Unit.PartOf;
    };

    Service = {
      Type = "simple";
      ExecStart = "${autorandr-trigger}/bin/autorandr-trigger";
      Restart = "on-failure";
      RestartSec = "5m";
    };

    Install.WantedBy = config.systemd.user.services.autorandr.Install.WantedBy;
  };
  /*
    systemd.user.services.autorandr = {
    Unit = {
      Description = "autorandr";
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.autorandr}/bin/autorandr --change";
    };

    Install.WantedBy = [ "graphical-session.target" ];
    };
  */
}
