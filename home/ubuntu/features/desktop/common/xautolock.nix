{ pkgs, ... }:

{
  services.screen-locker = {
    enable = true;
    inactiveInterval = 1;
    lockCmd = "${pkgs.i3lock}/bin/i3lock -n -c 01544A";

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
  };
}
