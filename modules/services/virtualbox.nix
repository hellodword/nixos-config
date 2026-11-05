{
  pkgs,
  lib,
  userName,
  config,
  ...
}:

let
  cfg = config.virtualisation.virtualbox.host;

  # 与 NixOS VirtualBox host 模块使用相同的参数，
  # 保证引用的是同一个 VirtualBox derivation。
  virtualbox = cfg.package.override {
    inherit (cfg)
      enableHardening
      headless
      enableWebService
      enableKvm
      ;

    extensionPack = if cfg.enableExtensionPack then pkgs.virtualboxExtpack else null;
  };

  # 只创建一个轻量级启动脚本。
  virtualboxLauncher = pkgs.writeShellScriptBin "VirtualBox" ''
    export ANV_DEBUG=video-decode,video-encode
    exec ${virtualbox}/bin/VirtualBox "$@"
  '';

in
{
  options.site.virtualbox.enable = lib.mkEnableOption "VirtualBox with the existing host integration";
  config = lib.mkIf config.site.virtualbox.enable {
    nixpkgs.config.allowUnfreePackages = [ "Oracle_VirtualBox_Extension_Pack" ];

    # VirtualBox is not currently allowed to access USB devices
    users.users."${userName}".extraGroups = [ "vboxusers" ];

    virtualisation.virtualbox = {
      host = {
        enable = true;
        package = (import ../../nix/packages.nix { inherit pkgs; }).virtualbox;
      };
    };

    environment.systemPackages = [
      (pkgs.lib.hiPrio virtualboxLauncher)
    ];

    # https://discourse.nixos.org/t/how-to-adjust-the-timeout-of-a-systemd-device/12620
    # Timed out waiting for device /dev/vboxguest
    systemd.units."dev-vboxguest.device".text = ''
      [Unit]
      ConditionVirtualization=oracle
    '';

    # https://github.com/NixOS/nixpkgs/issues/363887#issuecomment-2536693220
    boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];
  };
}
