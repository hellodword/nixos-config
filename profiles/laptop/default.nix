{
  config,
  ...
}:
{
  imports = [
    ./persistence.nix
    ./backup.nix
    ./network.nix
    ../../modules/desktop/fonts.nix
  ];
  site = {
    network.runtimeConnectionDirectory = "${config.site.storage.persistRoot}/usr/local/etc/network-policy/connection.d";
    network.runtimeRouteDirectory = "${config.site.storage.persistRoot}/usr/local/etc/network-policy/route.d";
    core.enable = true;
    cli.enable = true;
    desktop.enable = true;
    apps.enable = true;
    virtualbox.enable = true;
    connections.enable = true;
    android = {
      waydroid.enable = true;
      adb.enable = true;
    };
    productivity.enable = true;
    notifications.enable = true;
    containers.enable = true;
  };
  boot.supportedFilesystems = [
    "ntfs"
    "vfat"
    "ext4"
  ];
  hardware.graphics.enable = true;
  services.thermald.enable = true;
  services.libinput.touchpad = {
    tapping = true;
    naturalScrolling = false;
    disableWhileTyping = true;
    scrollMethod = "twofinger";
  };
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [
      "--shields-up=false"
      "--accept-dns=false"
      "--accept-routes=false"
      "--advertise-exit-node=true"
      "--snat-subnet-routes=true"
      "--advertise-routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    ];
    extraSetFlags = [
      "--shields-up=false"
      "--accept-dns=false"
      "--accept-routes=false"
      "--advertise-exit-node=true"
      "--snat-subnet-routes=true"
      "--advertise-routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    ];
  };

}
