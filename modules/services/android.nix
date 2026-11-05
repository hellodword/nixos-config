{
  config,
  lib,
  pkgs,
  userName,
  ...
}:
{
  options.site.android = {
    waydroid.enable = lib.mkEnableOption "Waydroid";
    adb.enable = lib.mkEnableOption "USB Android debugging";
  };
  config = lib.mkMerge [
    (lib.mkIf config.site.android.waydroid.enable {
      virtualisation.waydroid.enable = true;
    })
    (lib.mkIf config.site.android.adb.enable {
      # systemd supplies the device uaccess rules.
      users.users.${userName}.extraGroups = [ "kvm" ];
      environment.systemPackages = [ pkgs.android-tools ];
    })
  ];
}
