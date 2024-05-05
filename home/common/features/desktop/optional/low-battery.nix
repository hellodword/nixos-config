# { pkgs, ... }:

# let
#   # check = pkgs.writeShellApplication {
#   #   name = "check";
#   #   runtimeInputs = with pkgs; [ coreutils gnugrep libnotify systemd ];
#   #   text = ''
#   #     set -x

#   #     POWER_SUPPLY_CAPACITY="$(grep -oP '(?<=POWER_SUPPLY_CAPACITY=)\d+$' /sys/class/power_supply/BAT0/uevent)"
#   #     POWER_SUPPLY_ENERGY_NOW="$(grep -oP '(?<=POWER_SUPPLY_ENERGY_NOW=)\d+$' /sys/class/power_supply/BAT0/uevent)"
#   #     POWER_SUPPLY_ENERGY_FULL_DESIGN="$(grep -oP '(?<=POWER_SUPPLY_ENERGY_FULL_DESIGN=)\d+$' /sys/class/power_supply/BAT0/uevent)"
#   #     POWER_SUPPLY_STATUS="$(grep -oP '(?<=POWER_SUPPLY_STATUS=)[^\n]+$' /sys/class/power_supply/BAT0/uevent | tr '[:upper:]' '[:lower:]')"

#   #     POWER_SUPPLY_ONLINE="$(grep -oP '(?<=POWER_SUPPLY_ONLINE=)[^\n]+$' /sys/class/power_supply/AC0/uevent || true)"
#   #     if [ -z "$POWER_SUPPLY_ONLINE" ]; then
#   #       POWER_SUPPLY_ONLINE="$(grep -oP '(?<=POWER_SUPPLY_ONLINE=)[^\n]+$' /sys/class/power_supply/AC/uevent || true)"
#   #     fi

#   #     [ -n "$POWER_SUPPLY_CAPACITY" ]
#   #     [ -n "$POWER_SUPPLY_ENERGY_NOW" ]
#   #     [ -n "$POWER_SUPPLY_ENERGY_FULL_DESIGN" ]
#   #     [ -n "$POWER_SUPPLY_ONLINE" ]

#   #     if [ "$POWER_SUPPLY_ONLINE" != "1" ] && [ "$POWER_SUPPLY_STATUS" != "charging" ]; then

#   #       # 低于 10% 或者少于设计容量的 8% 关机
#   #       if [ "$POWER_SUPPLY_CAPACITY" -le "10" ] || [ "$POWER_SUPPLY_ENERGY_NOW" -le "$(("$POWER_SUPPLY_ENERGY_FULL_DESIGN" * 8 / 100))" ]; then
#   #         notify-send -u critical -t 3000 -a "电量不足！" "电量不足！马上关机！"
#   #         sleep 3s
#   #         systemctl poweroff

#   #       # 低于 30% 或者少于设计容量的 25% 警告
#   #       elif [ "$POWER_SUPPLY_CAPACITY" -le "30" ] || [ "$POWER_SUPPLY_ENERGY_NOW" -le "$(("$POWER_SUPPLY_ENERGY_FULL_DESIGN" * 25 / 100))" ]; then

#   #         notify-send -u critical -t 14000 -a "电量不足！" "电量不足！快充电！"

#   #       fi
#   #     fi
#   #   '';
#   # };
# in
{
  # systemd.user.services.low-battery = {
  #   Service = {
  #     Type = "oneshot";
  #     ExecStart = "${check}/bin/check";
  #     Restart = "on-failure";
  #     RestartSec = "5m";
  #   };
  # };
  # systemd.user.timers.low-battery = {
  #   Timer = {
  #     OnBootSec = "1m";
  #     OnUnitInactiveSec = "3m";
  #     # AccuracySec = "1us";
  #   };
  #   Install = { WantedBy = [ "timers.target" ]; };
  # };

  services.batsignal = {
    enable = true;
    extraArgs = [
      "-f99"
      "-w60"
      "-c50"
      "-d40"
    ];
  };
}
