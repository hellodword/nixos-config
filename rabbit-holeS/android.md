# android

- https://github.com/nix-community/robotnix
- https://wiki.nixos.org/wiki/Android
- https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/mobile/androidenv/examples
- https://github.com/search?q=%2FcomposeAndroidPackages%5B%5Cs%5CS%5D%2BmkShell%5B%5Cs%5CS%5D%2Bandroid-studio%2F+language%3Anix&type=code
- https://nixos.org/manual/nixpkgs/unstable/#android
- Flutter: https://github.com/tadfisher/android-nixpkgs/pull/73

```sh
avdmanager list avd
avdmanager delete avd -n test
avdmanager create avd -k 'system-images;android-34;default;x86_64' -n test
env ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL=999 emulator -avd test
```

## know issues

- https://github.com/tadfisher/android-nixpkgs/blob/2d8181caef279f19c4a33dc694723f89ffc195d4/README.md#troubleshooting

- Android Studio 里的 sdkmanager 和 device manager 显示的 system-images 不正确。例如只安装了 `system-images-android-34-default-x86-64`，但 device manager 里创建时只显示 `system-images-android-34-google-apis-x86-64` 已下载，而实际选择它时则又提示需要下载。可以通过 `avdmanager` 和 `emulator` 创建和运行

- Android Studio 内的 Terminal 无法打开

- Emulator 所有按键包括浮动侧栏上面的按键都不生效，可以通过类似 `adb shell input keyevent 3` `adb shell reboot -p` 等命令来控制

- `system-images;android-27;default;arm64-v8a` 无法启动
