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

## flutter

- https://github.com/NixOS/nixpkgs/blob/db5f88c41a638e4ff1f67a61310a6e958eaa07a8/pkgs/development/compilers/flutter/sdk-symlink.nix

- flutter 会在 `flutter doctor` 时报错 `Unable to determine bundled Java version`，需要 android-studio 的 FHS 环境。`pkgs.flutter*` 是一些 wrapper，不方便 override，可以用 symlinkJoin，但需要 `--set-default FLUTTER_ROOT "$out"`

- flutter 项目默认依赖的 gradle 版本与 nixpkgs 中的版本不一致，第一次 `flutter build apk` 时就会去拉对应版本的 gradle，网络不好就会超时，超时时间似乎是[硬编码](https://github.com/gradle/gradle/blob/73b46a83d30052c8bc5714373184f6ad9e74b3f5/platforms/core-runtime/wrapper-shared/src/main/java/org/gradle/wrapper/Install.java#L55)没法覆盖，可以手动下载到指定位置

- flutter 项目会依赖一些特定版本的 sdkmanager 中的包并且会在编译时尝试安装，例如 `flutter stable 3.19.0` 需要 `build-tools;30.0.3`，还没找到直接可以获取对应关系的地方。例如使用 `android-nixpkgs`，那么 `$ANDROID_SDK_ROOT` 只读，就会在 `flutter build apk` 时提示失败，补齐需要的包即可

## know issues

- https://github.com/tadfisher/android-nixpkgs/blob/2d8181caef279f19c4a33dc694723f89ffc195d4/README.md#troubleshooting

- ~~Android Studio 里的 sdkmanager 和 device manager 显示的 system-images 不正确。例如只安装了 `system-images-android-34-default-x86-64`，但 device manager 里创建时只显示 `system-images-android-34-google-apis-x86-64` 已下载，而实际选择它时则又提示需要下载。可以通过 `avdmanager` 和 `emulator` 创建和运行~~ 这是因为旧方式切换过来的 Android SDK 目录没改成 `android-sdk.path`，在 `Tools - SDK Manager` 里修改 `Android SDK Location`

- hm 里安装的 Android Studio 内的 Terminal 无法打开，以 nixos 方式安装则正常

- Emulator 所有按键包括浮动侧栏上面的按键都不生效，可以通过类似 `adb shell input keyevent 3` `adb shell reboot -p` 等命令来控制。最好还是在 Android Studio 中的 Running Devices 通过浮动窗口使用，但是退出 Android Studio 时无法停止:

```
WARN - #com.android.sdklib.deviceprovisioner.LocalEmulatorProvisionerPlugin - Emulator failed to disconnect within 1 minutes
WARN - #com.android.ddmlib - ADB rejected shell command (am force-stop com.example.myapplication): closed
WARN - Emulator: test - Emulator terminated with exit code 137
WARN - Emulator: Pixel 8 Pro API 34 - Emulator terminated with exit code 137
```

- `system-images;android-27;default;arm64-v8a` 无法启动
