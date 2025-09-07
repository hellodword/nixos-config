{ pkgs, ... }:

{
  # https://github.com/colemickens/nixcfg/blob/15905d9e42dad17fa609c204f2dc3367db96d6ce/mixins/android.nix#L6
  # programs.adb.enable = true;
  services.udev.packages = [
    pkgs.android-udev-rules
  ];

  # environment.systemPackages = with pkgs; [
  #   scrcpy
  # ];

  /*
    adb usb
    adb tcpip 5555
    adb connect 1.2.3.4
    scrcpy --serial=1.2.3.4
  */
}
