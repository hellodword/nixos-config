# android

- https://github.com/nix-community/robotnix
- https://wiki.nixos.org/wiki/Android
- https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/mobile/androidenv/examples
- https://github.com/search?q=%2FcomposeAndroidPackages%5B%5Cs%5CS%5D%2BmkShell%5B%5Cs%5CS%5D%2Bandroid-studio%2F+language%3Anix&type=code
- https://nixos.org/manual/nixpkgs/unstable/#android

```sh
avdmanager list avd
avdmanager delete avd -n test
avdmanager create avd -k 'system-images;android-34;default;x86_64' -n test
env ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL=999 emulator -avd test
```
