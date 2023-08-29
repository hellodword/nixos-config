{ pkgs, ... }:

{
  home.packages = with pkgs; [
    scrcpy
  ];

  /*
    adb usb
    adb tcpip 5555
    adb connect 1.2.3.4
    scrcpy --serial=1.2.3.4
  */
}
