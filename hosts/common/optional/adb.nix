{
  pkgs,
  persistPath,
  userName,
  ...
}:

{
  # https://wiki.nixos.org/wiki/Android
  users.users."${userName}".extraGroups = [
    "adbusers"
    "kvm"
  ];

  environment.systemPackages = with pkgs; [
    android-tools
  ];

  /*
    adb usb
    adb tcpip 5555
    adb connect 1.2.3.4
    scrcpy --serial=1.2.3.4
  */

  # ".android"
  environment.persistence = {
    "${persistPath}" = {
      users."${userName}" = {
        directories = [
          ".android"
        ];
      };
    };
  };
}
