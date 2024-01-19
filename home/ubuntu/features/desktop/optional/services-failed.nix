{ pkgs, ... }:

let
  systemd-failed-notifier = pkgs.writeShellApplication {
    name = "systemd-failed-notifier";
    runtimeInputs = with pkgs; [ findutils libnotify systemd ];
    # https://forum.manjaro.org/t/is-there-a-simple-way-to-set-up-dynamic-wallpaper-switching-in-sway-for-dual-displays/85568/4
    text = ''
      systemctl --failed --quiet --no-pager | xargs -I {} notify-send --expire-time=0 --urgency=critical 'systemd' '{}'
      systemctl --user --failed --quiet --no-pager | xargs -I {} notify-send --expire-time=0 --urgency=critical 'systemd --user' '{}'
    '';
  };
in
{
  # TODO database / cache
  # TODO email / bark
  # TODO replace with logwatch
  systemd.user.services.services-failed = {
    Service = {
      Type = "oneshot";
      ExecStart = "${systemd-failed-notifier}/bin/systemd-failed-notifier";
      Restart = "on-failure";
      RestartSec = "5m";
    };
  };
  systemd.user.timers.services-failed = {
    Timer = {
      OnBootSec = "1m";
      OnUnitInactiveSec = "30s";
      # AccuracySec = "1us";
    };
    Install = { WantedBy = [ "timers.target" ]; };
  };
}
