{
  pkgs,
  nixosConfig,
  lib,
  ...
}:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
  lockCmd = "${
    if X then "${pkgs.i3lock}/bin/i3lock" else "${pkgs.swaylock}/bin/swaylock -f"
  } -n -c 01544A";
in
{
  services.screen-locker = (
    lib.optionalAttrs X {
      enable = true;
      inactiveInterval = 1;
      lockCmd = lockCmd;

      # lock before suspending/hibernating, see https://github.com/i3/i3lock/issues/207
      xss-lock.extraOptions = [ "--transfer-sleep-lock" ];

      xautolock = {
        enable = true;
        detectSleep = true;
        extraOptions = [
          "-notify"
          "3"
          "-notifier"
          "'${pkgs.libnotify}/bin/notify-send \"锁屏提示:\" \"还有3秒钟我就要自动锁屏了!\"'"
        ];
      };
    }
  );

  services.swayidle = (
    lib.optionalAttrs (!X) {
      enable = true;
      systemdTarget = "sway-session.target";
      events = [
        {
          event = "before-sleep";
          command = lockCmd;
        }
        {
          event = "lock";
          command = lockCmd;
        }
      ];
      timeouts = [
        {
          timeout = 60;
          command = "${pkgs.libnotify}/bin/notify-send --expire-time=3000 \"锁屏提示:\" \"还有3秒钟我就要自动锁屏了!\"";
        }
        {
          timeout = 64;
          command = lockCmd;
        }
      ];
    }
  );
}
