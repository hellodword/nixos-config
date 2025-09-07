{ persistPath, userName, ... }:

{
  # bug:
  # https://github.com/waydroid/waydroid/issues/1969
  # fix with `waydroid upgrade`

  # resize
  # waydroid prop set persist.waydroid.width 600
  # waydroid prop set persist.waydroid.height 600

  # github.com/waydroid/waydroid/issues/700
  # echo "ro.sf.lcd_density=215" | sudo tee -a /var/lib/waydroid/waydroid_base.prop

  virtualisation.waydroid.enable = true;

  environment.persistence = {
    "${persistPath}" = {
      directories = [
        "/var/lib/waydroid"
      ];

      users."${userName}" = {
        directories = [
          ".local/share/waydroid"
        ];
      };
    };
  };
}
